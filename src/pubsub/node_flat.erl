%%% ====================================================================
%%% ``The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved via the world wide web at http://www.erlang.org/.
%%%
%%%
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%%
%%%
%%% The Initial Developer of the Original Code is ProcessOne.
%%% Portions created by ProcessOne are Copyright 2006-2015, ProcessOne
%%% All Rights Reserved.''
%%% This software is copyright 2006-2015, ProcessOne.
%%%
%%% @copyright 2006-2015 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

%%% @doc The module <strong>{@module}</strong> is the default PubSub plugin.
%%% <p>It is used as a default for all unknown PubSub node type.  It can serve
%%% as a developer basis and reference to build its own custom pubsub node
%%% types.</p>
%%% <p>PubSub plugin nodes are using the {@link gen_node} behaviour.</p>

-module(node_flat).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").
-include("mongoose.hrl").

-export([init/3, terminate/2, options/0, features/0,
         create_node_permission/6, create_node/2, delete_node/1,
         purge_node/2, subscribe_node/8, unsubscribe_node/4,
         publish_item/9, delete_item/4, remove_extra_items/3,
         get_entity_affiliations/2, get_node_affiliations/1,
         get_affiliation/2, set_affiliation/3,
         get_entity_subscriptions/2, get_node_subscriptions/1,
         get_subscriptions/2, set_subscriptions/4,
         get_pending_nodes/2,
         get_items/7, get_items/3, get_item/7,
         get_item/2, set_item/1, get_item_name/3, node_to_path/1,
         path_to_node/1, can_fetch_item/2, is_subscribed/1]).

init(_Host, _ServerHost, _Opts) ->
    pubsub_subscription:init(),
    ok.

terminate(_Host, _ServerHost) ->
    ok.

options() ->
    [{deliver_payloads, true},
        {notify_config, false},
        {notify_delete, false},
        {notify_retract, false},
        {purge_offline, false},
        {persist_items, true},
        {max_items, ?MAXITEMS},
        {subscribe, true},
        {access_model, open},
        {roster_groups_allowed, []},
        {publish_model, publishers},
        {notification_type, headline},
        {max_payload_size, ?MAX_PAYLOAD_SIZE},
        {send_last_published_item, never},
        {deliver_notifications, true},
        {presence_based_delivery, false}].

features() ->
    [<<"create-nodes">>,
        <<"auto-create">>,
        <<"access-authorize">>,
        <<"delete-nodes">>,
        <<"delete-items">>,
        <<"get-pending">>,
        <<"instant-nodes">>,
        <<"manage-subscriptions">>,
        <<"modify-affiliations">>,
        <<"outcast-affiliation">>,
        <<"persistent-items">>,
        <<"publish">>,
        <<"publish-only-affiliation">>,
        <<"purge-nodes">>,
        <<"retract-items">>,
        <<"retrieve-affiliations">>,
        <<"retrieve-items">>,
        <<"retrieve-subscriptions">>,
        <<"subscribe">>,
        <<"subscription-notifications">>].
%%<<"subscription-options">>

%% @doc Checks if the current user has the permission to create the requested node
%% <p>In flat node, any unused node name is allowed. The access parameter is also
%% checked. This parameter depends on the value of the
%% <tt>access_createnode</tt> ACL value in ejabberd config file.</p>
create_node_permission(Host, ServerHost, _Node, _ParentNode, Owner, Access) ->
    Allowed = case jid:to_lower(Owner) of
        {<<"">>, Host, <<"">>} ->
            true; % pubsub service always allowed
        _ ->
            acl:match_rule(ServerHost, Access, Owner) =:= allow
    end,
    {result, Allowed}.

create_node(Nidx, Owner) ->
    mod_pubsub_db_backend:set_affiliation(Nidx, jid:to_bare(Owner), owner),
    {result, {default, broadcast}}.

delete_node(Nodes) ->
    Tr = fun (#pubsub_state{stateid = {J, _}, subscriptions = Ss}) ->
            lists:map(fun (S) -> {J, S} end, Ss)
    end,
    Reply = lists:map(fun (#pubsub_node{id = Nidx} = PubsubNode) ->
                    {ok, States} = mod_pubsub_db_backend:get_states(Nidx),
                    lists:foreach(fun (#pubsub_state{stateid = {LJID, _}, items = Items}) ->
                                del_items(Nidx, Items),
                                mod_pubsub_db_backend:del_state(Nidx, LJID)
                        end, States),
                    {PubsubNode, lists:flatmap(Tr, States)}
            end, Nodes),
    {result, {default, broadcast, Reply}}.

%% @doc <p>Accepts or rejects subcription requests on a PubSub node.</p>
%% <p>The mechanism works as follow:
%% <ul>
%% <li>The main PubSub module prepares the subscription and passes the
%% result of the preparation as a record.</li>
%% <li>This function gets the prepared record and several other parameters and
%% can decide to:<ul>
%%  <li>reject the subscription;</li>
%%  <li>allow it as is, letting the main module perform the database
%%  persistance;</li>
%%  <li>allow it, modifying the record. The main module will store the
%%  modified record;</li>
%%  <li>allow it, but perform the needed persistance operations.</li></ul>
%% </li></ul></p>
%% <p>The selected behaviour depends on the return parameter:
%%  <ul>
%%   <li><tt>{error, Reason}</tt>: an IQ error result will be returned. No
%%   subscription will actually be performed.</li>
%%   <li><tt>true</tt>: Subscribe operation is allowed, based on the
%%   unmodified record passed in parameter <tt>SubscribeResult</tt>. If this
%%   parameter contains an error, no subscription will be performed.</li>
%%   <li><tt>{true, PubsubState}</tt>: Subscribe operation is allowed, but
%%   the {@link mod_pubsub:pubsubState()} record returned replaces the value
%%   passed in parameter <tt>SubscribeResult</tt>.</li>
%%   <li><tt>{true, done}</tt>: Subscribe operation is allowed, but the
%%   {@link mod_pubsub:pubsubState()} will be considered as already stored and
%%   no further persistance operation will be performed. This case is used,
%%   when the plugin module is doing the persistance by itself or when it want
%%   to completly disable persistance.</li></ul>
%% </p>
%% <p>In the default plugin module, the record is unchanged.</p>
subscribe_node(Nidx, Sender, Subscriber, AccessModel,
            SendLast, PresenceSubscription, RosterGroup, _Options) ->
    SenderMatchesSubscriber = jid:are_bare_equal(Sender, Subscriber),
    {ok, Affiliation} = mod_pubsub_db_backend:get_affiliation(Nidx, Subscriber),
    {ok, Subscriptions} = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, Subscriber),
    Whitelisted = lists:member(Affiliation, [member, publisher, owner]),
    PendingSubscription = lists:any(fun
                ({pending, _}) -> true;
                (_) -> false
            end,
            Subscriptions),
    case authorize_subscription(SenderMatchesSubscriber, Affiliation, PendingSubscription,
                               AccessModel, PresenceSubscription, RosterGroup, Whitelisted) of
        ok ->
            {NewSub, SubId} = case Subscriptions of
                [{subscribed, Id}|_] ->
                    {subscribed, Id};
                [] ->
                    Id = pubsub_subscription:make_subid(),
                    Sub = access_model_to_subscription(AccessModel),
                    mod_pubsub_db_backend:add_subscription(Nidx, Subscriber, Sub, Id),
                    {Sub, Id}
            end,
            case {NewSub, SendLast} of
                {subscribed, never} ->
                    {result, {default, subscribed, SubId}};
                {subscribed, _} ->
                    {result, {default, subscribed, SubId, send_last}};
                {_, _} ->
                    {result, {default, pending, SubId}}
            end;
        {error, _} = Err ->
            Err
    end.

-spec access_model_to_subscription(accessModel()) -> pending | subscribed.
access_model_to_subscription(authorize) -> pending;
access_model_to_subscription(_) -> subscribed.

-spec authorize_subscription(SenderMatchesSubscriber :: boolean(),
                            Affiliation :: affiliation(),
                            PendingSubscription :: boolean(),
                            AccessModel :: accessModel(),
                            PresenceSubscription :: boolean(),
                            RosterGroup :: boolean(),
                            Whitelisted :: boolean()) -> ok | {error, exml:element()}.
authorize_subscription(false, _Affiliation, _PendingSubscription, _AccessModel,
                       _PresenceSubscription, _RosterGroup, _Whitelisted) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:bad_request()), <<"invalid-jid">>)};
authorize_subscription(_SenderMatchesSubscriber, Affiliation, _PendingSubscription, _AccessModel,
                       _PresenceSubscription, _RosterGroup, _Whitelisted)
  when (Affiliation == outcast) or (Affiliation == publish_only) ->
    {error, mongoose_xmpp_errors:forbidden()};
authorize_subscription(_SenderMatchesSubscriber, _Affiliation, true, _AccessModel,
                       _PresenceSubscription, _RosterGroup, _Whitelisted) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_authorized()), <<"pending-subscription">>)};
authorize_subscription(_SenderMatchesSubscriber, Affiliation, _PendingSubscription, presence,
                       false, _RosterGroup, _Whitelisted) when Affiliation /= owner ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_authorized()), <<"presence-subscription-required">>)};
authorize_subscription(_SenderMatchesSubscriber, Affiliation, _PendingSubscription, roster,
                       _PresenceSubscription, false, _Whitelisted) when Affiliation /= owner ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_authorized()), <<"not-in-roster-group">>)};
authorize_subscription(_SenderMatchesSubscriber, Affiliation, _PendingSubscription, whitelist,
                       _PresenceSubscription, _RosterGroup, false) when Affiliation /= owner ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_allowed()), <<"closed-node">>)};
authorize_subscription(_SenderMatchesSubscriber, _Affiliation, _PendingSubscription, _AccessModel,
                       _PresenceSubscription, _RosterGroup, _Whitelisted) ->
    ok.

%% @doc <p>Unsubscribe the <tt>Subscriber</tt> from the <tt>Node</tt>.</p>
unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    SenderMatchesSubscriber = jid:are_bare_equal(Subscriber, Sender),
    {ok, Subscriptions} = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, Subscriber),
    SubIdExists = case SubId of
                      <<>> -> false;
                      Binary when is_binary(Binary) -> true;
                      _ -> false
                  end,
    case authenticate_unsubscribe(SenderMatchesSubscriber, Subscriptions, SubIdExists, SubId) of
        sub_id_exists ->
            case lists:keyfind(SubId, 2, Subscriptions) of
                false ->
                    {error,
                     ?ERR_EXTENDED((mongoose_xmpp_errors:unexpected_request_cancel()),
                                   <<"not-subscribed">>)};
                _S ->
                    mod_pubsub_db_backend:delete_subscription(Nidx, Subscriber, SubId),
                    {result, default}
            end;
        remove_all_subs ->
            mod_pubsub_db_backend:delete_all_subscriptions(Nidx, Subscriber),
            {result, default};
        remove_only_sub ->
            mod_pubsub_db_backend:delete_all_subscriptions(Nidx, Subscriber),
            {result, default}
    end.

authenticate_unsubscribe(false, _Subscriptions, _SubIdExists, _SubId) ->
    {error, mongoose_xmpp_errors:forbidden()};
authenticate_unsubscribe(_SenderMatchesSubscriber, [], _SubIdExists, _SubId) ->
    %% Requesting entity is not a subscriber
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:unexpected_request_cancel()), <<"not-subscribed">>)};
authenticate_unsubscribe(_SenderMatchesSubscriber, _Subscriptions, true, _SubId) ->
    %% Subid supplied, so use that.
    sub_id_exists;
authenticate_unsubscribe(_SenderMatchesSubscriber, _Subscriptions, _SubIdExists, all) ->
    %% Asking to remove all subscriptions to the given node
    remove_all_subs;
authenticate_unsubscribe(_SenderMatchesSubscriber, [_], _SubIdExists, _SubId) ->
    %% No subid supplied, but there's only one matching subscription
    remove_only_sub;
authenticate_unsubscribe(_SenderMatchesSubscriber, _Subscriptions, _SubIdExists, _SubId) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:bad_request()), <<"subid-required">>)}.

%% @doc <p>Publishes the item passed as parameter.</p>
%% <p>The mechanism works as follow:
%% <ul>
%% <li>The main PubSub module prepares the item to publish and passes the
%% result of the preparation as a {@link mod_pubsub:pubsubItem()} record.</li>
%% <li>This function gets the prepared record and several other parameters and can decide to:<ul>
%%  <li>reject the publication;</li>
%%  <li>allow the publication as is, letting the main module perform the database persistance;</li>
%%  <li>allow the publication, modifying the record.
%%      The main module will store the modified record;</li>
%%  <li>allow it, but perform the needed persistance operations.</li></ul>
%% </li></ul></p>
%% <p>The selected behaviour depends on the return parameter:
%%  <ul>
%%   <li><tt>{error, Reason}</tt>: an iq error result will be return. No
%%   publication is actually performed.</li>
%%   <li><tt>true</tt>: Publication operation is allowed, based on the
%%   unmodified record passed in parameter <tt>Item</tt>. If the <tt>Item</tt>
%%   parameter contains an error, no subscription will actually be
%%   performed.</li>
%%   <li><tt>{true, Item}</tt>: Publication operation is allowed, but the
%%   {@link mod_pubsub:pubsubItem()} record returned replaces the value passed
%%   in parameter <tt>Item</tt>. The persistance will be performed by the main
%%   module.</li>
%%   <li><tt>{true, done}</tt>: Publication operation is allowed, but the
%%   {@link mod_pubsub:pubsubItem()} will be considered as already stored and
%%   no further persistance operation will be performed. This case is used,
%%   when the plugin module is doing the persistance by itself or when it want
%%   to completly disable persistance.</li></ul>
%% </p>
%% <p>In the default plugin module, the record is unchanged.</p>
publish_item(_ServerHost, Nidx, Publisher, PublishModel, MaxItems, ItemId, ItemPublisher,
             Payload, _PublishOptions) ->
    %% vvvvvvvvvvvv
    BarePublisher = jid:to_bare(Publisher),
    SubKey = jid:to_lower(Publisher),
    GenKey = jid:to_lower(BarePublisher),
    {ok, GenState} = mod_pubsub_db_backend:get_state(Nidx, BarePublisher),
    SubState = case Publisher#jid.lresource of
                   <<>> ->
                       GenState;
                   _ ->
                       {ok, SubState0} = mod_pubsub_db_backend:get_state(Nidx, Publisher),
                       SubState0
               end,
    {ok, Affiliation} = mod_pubsub_db_backend:get_affiliation(Nidx, Publisher),
    Subscribed = case PublishModel of
        subscribers -> is_subscribed(GenState#pubsub_state.subscriptions) orelse
                       is_subscribed(SubState#pubsub_state.subscriptions);
        _ -> undefined
    end,
    %% ^^^^^^^^^^^^ TODO: Whole this block may be refactored when we migrate pubsub_item
    %%                    as GenState won't be needed anymore.
    Allowed = (PublishModel == open) or
              (PublishModel == publishers) and
              ( (Affiliation == owner) or
                (Affiliation == publisher) or
                (Affiliation == publish_only) ) or
              (Subscribed == true),
    case Allowed of
        false  ->
            {error, mongoose_xmpp_errors:forbidden()};
        true ->
            case MaxItems > 0 of
               true ->
                   Now = os:timestamp(),
                   Item = make_pubsub_item(Nidx, ItemId, Now, SubKey, GenKey,
                                           Payload, Publisher, ItemPublisher),
                   Items = [ItemId | GenState#pubsub_state.items -- [ItemId]],
                   {result, {_NI, OI}} = remove_extra_items(Nidx, MaxItems, Items),
                   set_item(Item),
                   mod_pubsub_db_backend:add_item(Nidx, Publisher, ItemId),
                   mod_pubsub_db_backend:remove_items(Nidx, Publisher, OI),
                   {result, {default, broadcast, OI}};
               false ->
                   {result, {default, broadcast, []}}
            end
    end.

make_pubsub_item(Nidx, ItemId, Now, SubKey, GenKey, Payload, Publisher, ItemPublisher) ->
    PubId = {Now, SubKey},
    case get_item(Nidx, ItemId) of
        {result, OldItem} ->
            OldItem#pubsub_item{modification = PubId,
                                payload = Payload};
        _ ->
            Publisher0 = case ItemPublisher of
                             true -> Publisher;
                             false -> undefined
                         end,
            #pubsub_item{itemid = {ItemId, Nidx},
                         creation = {Now, GenKey},
                         modification = PubId,
                         publisher = Publisher0,
                         payload = Payload}
    end.

%% @doc <p>This function is used to remove extra items, most notably when the
%% maximum number of items has been reached.</p>
%% <p>This function is used internally by the core PubSub module, as no
%% permission check is performed.</p>
%% <p>In the default plugin module, the oldest items are removed, but other
%% rules can be used.</p>
%% <p>If another PubSub plugin wants to delegate the item removal (and if the
%% plugin is using the default pubsub storage), it can implements this function like this:
%% ```remove_extra_items(Nidx, MaxItems, ItemIds) ->
%%           node_default:remove_extra_items(Nidx, MaxItems, ItemIds).'''</p>
remove_extra_items(_Nidx, unlimited, ItemIds) ->
    {result, {ItemIds, []}};
remove_extra_items(Nidx, MaxItems, ItemIds) ->
    NewItems = lists:sublist(ItemIds, MaxItems),
    OldItems = lists:nthtail(length(NewItems), ItemIds),
    del_items(Nidx, OldItems),
    {result, {NewItems, OldItems}}.

%% @doc <p>Triggers item deletion.</p>
%% <p>Default plugin: The user performing the deletion must be the node owner
%% or a publisher, or PublishModel being open.</p>
delete_item(Nidx, Publisher, PublishModel, ItemId) ->
    GenKey = jid:to_bare(jid:to_lower(Publisher)),
    {ok, GenState} = mod_pubsub_db_backend:get_state(Nidx, jid:to_bare(Publisher)),
    #pubsub_state{affiliation = Affiliation, items = Items} = GenState,
    Allowed = Affiliation == publisher orelse
        Affiliation == owner orelse
        PublishModel == open orelse
        case get_item(Nidx, ItemId) of
        {result, #pubsub_item{creation = {_, GenKey}}} -> true;
        _ -> false
    end,
    case Allowed of
        false ->
            {error, mongoose_xmpp_errors:forbidden()};
        true ->
            case lists:member(ItemId, Items) of
                true ->
                    del_item(Nidx, ItemId),
                    mod_pubsub_db_backend:remove_items(Nidx, Publisher, [ItemId]),
                    {result, {default, broadcast}};
                false ->
                    delete_foreign_item(Nidx, ItemId, Affiliation)
            end
    end.

%% Delete an item that does not belong to the user
%% TODO: Whole function should be moved to DB layer but we need to migrate pubsub_item first
delete_foreign_item(Nidx, ItemId, owner) ->
    {ok, States} = mod_pubsub_db_backend:get_states(Nidx),
    lists:foldl(fun
                    (#pubsub_state{stateid = {User, _}, items = PI}, Res) ->
                        case lists:member(ItemId, PI) of
                            true ->
                                del_item(Nidx, ItemId),
                                mod_pubsub_db_backend:remove_items(Nidx, User, [ItemId]),
                                {result, {default, broadcast}};
                            false ->
                                Res
                        end;
                    (_, Res) ->
                        Res
                end,
                {error, mongoose_xmpp_errors:item_not_found()}, States);
delete_foreign_item(_Nidx, _ItemId, _Affiliation) ->
    {error, mongoose_xmpp_errors:item_not_found()}.

purge_node(Nidx, Owner) ->
    case mod_pubsub_db_backend:get_affiliation(Nidx, Owner) of
        {ok, owner} ->
            {ok, States} = mod_pubsub_db_backend:get_states(Nidx),
            lists:foreach(fun
                    (#pubsub_state{items = []}) ->
                        ok;
                    (#pubsub_state{items = Items}) ->
                        del_items(Nidx, Items)
                end,
                States),
            mod_pubsub_db_backend:remove_all_items(Nidx),
            {result, {default, broadcast}};
        _ ->
            {error, mongoose_xmpp_errors:forbidden()}
    end.

get_entity_affiliations(Host, Owner) ->
    {ok, States} = mod_pubsub_db_backend:get_states_by_bare(Owner),
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {_, N}, affiliation = A}, Acc) ->
                                case gen_pubsub_nodetree:get_node(NodeTree, N) of
                                    #pubsub_node{nodeid = {Host, _}} = Node -> [{Node, A} | Acc];
                                    _ -> Acc
                                end
                        end,
                        [], States),
    {result, Reply}.

get_node_affiliations(Nidx) ->
    {ok, States} = mod_pubsub_db_backend:get_states(Nidx),
    Tr = fun (#pubsub_state{stateid = {J, _}, affiliation = A}) -> {J, A} end,
    {result, lists:map(Tr, States)}.

get_affiliation(Nidx, Owner) ->
    {ok, Affiliation} = mod_pubsub_db_backend:get_affiliation(Nidx, Owner),
    {result, Affiliation}.

set_affiliation(Nidx, Owner, Affiliation) ->
    mod_pubsub_db_backend:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    States = case Owner#jid.lresource of
                 <<>> ->
                     {ok, States0} = mod_pubsub_db_backend:get_states_by_lus(Owner),
                     States0;
                 _ ->
                     {ok, States0} = mod_pubsub_db_backend:get_states_by_bare_and_full(Owner),
                     States0
             end,
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (PubSubState, Acc) ->
                                get_entity_subscriptions_loop(NodeTree, PubSubState, Acc)
                        end,
                        [], States),
    {result, Reply}.

get_entity_subscriptions_loop(NodeTree, #pubsub_state{stateid = {J, N}, subscriptions = Ss}, Acc) ->
    case gen_pubsub_nodetree:get_node(NodeTree, N) of
        #pubsub_node{} = Node ->
            lists:foldl(fun ({Sub, SubId}, Acc2) -> [{Node, Sub, SubId, J} | Acc2] end, Acc, Ss);
        _ ->
            Acc
    end.

get_node_subscriptions(Nidx) ->
    {ok, Subscriptions} = mod_pubsub_db_backend:get_node_subscriptions(Nidx),
    {result, Subscriptions}.

get_subscriptions(Nidx, Owner) ->
    {ok, Subscriptions} = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, Owner),
    {result, Subscriptions}.

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    {ok, Subscriptions} = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, Owner),
    case {SubId, Subscriptions} of
        {_, []} ->
            case Subscription of
                none ->
                    {error,
                        ?ERR_EXTENDED((mongoose_xmpp_errors:bad_request()), <<"not-subscribed">>)};
                _ ->
                    NewSubId = pubsub_subscription:make_subid(),
                    mod_pubsub_db_backend:add_subscription(Nidx, Owner, Subscription, NewSubId)
            end;
        {<<>>, [{_, SID}]} ->
            case Subscription of
                none -> mod_pubsub_db_backend:delete_subscription(Nidx, Owner, SID);
                _ -> mod_pubsub_db_backend:update_subscription(Nidx, Owner, Subscription, SID)
            end;
        {<<>>, [_ | _]} ->
            {error,
                ?ERR_EXTENDED((mongoose_xmpp_errors:bad_request()), <<"subid-required">>)};
        _ ->
            case Subscription of
                none -> mod_pubsub_db_backend:delete_subscription(Nidx, Owner, SubId);
                _ -> mod_pubsub_db_backend:update_subscription(Nidx, Owner, Subscription, SubId)
            end
    end.

%% @doc <p>Returns a list of Owner's nodes on Host with pending
%% subscriptions.</p>
get_pending_nodes(Host, Owner) ->
    {ok, States} = mod_pubsub_db_backend:get_own_nodes_states(Owner),
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (PubSubState, Acc) ->
                                case get_node_if_has_pending_subs(NodeTree, PubSubState) of
                                    {value, Node} -> [Node | Acc];
                                    false -> Acc
                                end
                         end,
                         [], States),
    {result, Reply}.

get_node_if_has_pending_subs(NodeTree, #pubsub_state{stateid = {_, N}, subscriptions = Subs}) ->
    HasPending = fun
        ({pending, _}) -> true;
        (pending) -> true;
        (_) -> false
    end,
    case lists:any(HasPending, Subs) of
        true ->
            case gen_pubsub_nodetree:get_node(NodeTree, N) of
                #pubsub_node{nodeid = {_, Node}} -> {value, Node};
                _ -> false
            end;
        false ->
            false
    end.

%% @doc Returns the list of stored items for a given node.
%% <p>For the default PubSub module, items are stored in Mnesia database.</p>
%% <p>We can consider that the pubsub_item table have been created by the main
%% mod_pubsub module.</p>
%% <p>PubSub plugins can store the items where they wants (for example in a
%% relational database), or they can even decide not to persist any items.</p>
get_items(Nidx, _From, _RSM) ->
    mod_pubsub_db_backend:get_items(Nidx).

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, _SubId, RSM) ->
    {ok, Affiliation} = mod_pubsub_db_backend:get_affiliation(Nidx, JID),
    {ok, BareSubscriptions}
    = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, jid:to_bare(JID)),
    {ok, FullSubscriptions}
    = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, JID),
    Whitelisted = can_fetch_item(Affiliation, BareSubscriptions) orelse
                  can_fetch_item(Affiliation, FullSubscriptions),
    case authorize_get_item(Affiliation, AccessModel, PresenceSubscription,
                            RosterGroup, Whitelisted) of
        ok -> get_items(Nidx, JID, RSM);
        {error, _} = Err -> Err
    end.

%% @doc <p>Returns an item (one item list), given its reference.</p>

get_item(Nidx, ItemId) ->
    mod_pubsub_db_backend:get_item(Nidx, ItemId).

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, _SubId) ->
    {ok, Affiliation} = mod_pubsub_db_backend:get_affiliation(Nidx, JID),
    {ok, Subscriptions}
    = mod_pubsub_db_backend:get_node_entity_subscriptions(Nidx, jid:to_bare(JID)),
    Whitelisted = can_fetch_item(Affiliation, Subscriptions),
    case authorize_get_item(Affiliation, AccessModel, PresenceSubscription,
                           RosterGroup, Whitelisted) of
        ok -> get_item(Nidx, ItemId);
        {error, _} = Err -> Err
    end.

authorize_get_item(Affiliation, _AccessModel, _PresenceSubscription, _RosterGroup, _Whitelisted)
  when (Affiliation == outcast) or (Affiliation == publish_only) ->
    {error, mongoose_xmpp_errors:forbidden()};
authorize_get_item(_Affiliation, presence, false, _RosterGroup, _Whitelisted) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_authorized()), <<"presence-subscription-required">>)};
authorize_get_item(_Affiliation, roster, _PresenceSubscription, false, _Whitelisted) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_authorized()), <<"not-in-roster-group">>)};
authorize_get_item(_Affiliation, whitelist, _PresenceSubscription, _RosterGroup, false) ->
    {error, ?ERR_EXTENDED((mongoose_xmpp_errors:not_allowed()), <<"closed-node">>)};
authorize_get_item(_Affiliation, authorize, _PresenceSubscription, _RosterGroup, false) ->
    {error, mongoose_xmpp_errors:forbidden()};
authorize_get_item(_Affiliation, _AccessModel, _PresenceSubscription, _RosterGroup, _Whitelisted) ->
    ok.

%% @doc <p>Write an item into database.</p>
set_item(Item) when is_record(Item, pubsub_item) ->
    mod_pubsub_db_backend:set_item(Item).
%set_item(_) -> {error, mongoose_xmpp_errors:internal_server_error()}.

%% @doc <p>Delete an item from database.</p>
del_item(Nidx, ItemId) ->
    mod_pubsub_db_backend:del_item(Nidx, ItemId).

del_items(Nidx, ItemIds) ->
    lists:foreach(fun (ItemId) -> del_item(Nidx, ItemId)
        end,
        ItemIds).

get_item_name(_Host, _Node, Id) ->
    Id.

%% @doc <p>Return the path of the node. In flat it's just node id.</p>
node_to_path(Node) ->
    [(Node)].

path_to_node(Path) ->
    case Path of
        % default slot
        [Node] -> iolist_to_binary(Node);
        % handle old possible entries, used when migrating database content to new format
        [Node | _] when is_binary(Node) ->
            mongoose_bin:join([<<"">> | Path], <<"/">>);
        % default case (used by PEP for example)
        _ -> iolist_to_binary(Path)
    end.

can_fetch_item(owner, _) -> true;
can_fetch_item(member, _) -> true;
can_fetch_item(publisher, _) -> true;
can_fetch_item(publish_only, _) -> false;
can_fetch_item(outcast, _) -> false;
can_fetch_item(none, Subscriptions) -> is_subscribed(Subscriptions).
%can_fetch_item(_Affiliation, _Subscription) -> false.

is_subscribed(Subscriptions) ->
    lists:any(fun
            ({subscribed, _SubId}) -> true;
            (_) -> false
        end,
        Subscriptions).


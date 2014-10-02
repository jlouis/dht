%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc DHT networking code
%% @end
%% @private
-module(dht_net).

-behaviour(gen_server).

%%
%% Implementation notes
%%     RPC calls to remote nodes in the DHT are written by use of a gen_server proxy.
%%     The proxy maintains an internal correlation table from requests to replies so
%%     a given reply can be matched up with the correct requestor. It uses the
%%     standard gen_server:call/3 approach to handling calls in the DHT.
%%
%%     A timer is used to notify the server of requests that
%%     time out, if a request times out {error, timeout} is
%%     returned to the client. If a response is received after
%%     the timer has fired, the response is dropped.
%%
%%     The expected behavior is that the high-level timeout fires
%%     before the gen_server call times out, therefore this interval
%%     should be shorter then the interval used by gen_server calls.
%%
%%     The find_node_search/1 and get_peers_search/1 functions
%%     are almost identical, they both recursively search for the
%%     nodes closest to an id. The difference is that get_peers should
%%     return as soon as it finds a node that acts as a tracker for
%%     the infohash.

%% Lifetime interface. Mostly has to do with setup and configuration
-export([start_link/1, node_port/0]).

%% DHT API
-export([
         announce/4,
         find_node/3,
         get_peers/3,
         ping/2,
         return/3
]).

%% API for iterative search functions
-export([
         find_node_search/1,
         find_node_search/2,
         get_peers_search/1,
         get_peers_search/2
]).


-type trackerinfo() :: {dht:node_id(), inet:ip_address(), inet:port_number(), token()}.
-type infohash() :: integer().
-type token() :: binary().
%%  -type dht_qtype() :: ping | find_node | get_peers | announce. %% This has to change

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports

-record(state, {
    socket :: inet:socket(),
    sent   :: gb_trees:tree(),
    tokens :: queue:queue()
}).

-define(TOKEN_LIFETIME, 5 * 60 * 1000).
-define(UDP_MAILBOX_SZ, 16).

%
% Constants and settings
%
query_timeout() -> 2000.
search_width() -> 32.
search_retries() -> 4.

socket_options() ->
    {ok, Base} = application:get_env(dht, listen_opts),
    [list, inet, {active, ?UDP_MAILBOX_SZ} | Base].


%
% Public interface
%

%% @doc Start up the DHT networking subsystem
%% @end
start_link(DHTPort) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [DHTPort], []).

%% @doc node_port/0 returns the (UDP) port number to which the DHT system is bound.
%% @end
-spec node_port() -> {inet:ip_adress(), inet:port_number()}.
node_port() ->
    gen_server:call(?MODULE, node_port).

%% @doc ping/2 sends a ping to a node
%% Calling `ping(IP, Port)' will send a ping message to the IP/Port pair
%% and wait for a result to come back. Used to check if the node in the
%% other end is up and running.
%% @end
-spec ping(inet:ip_address(), inet:port_number()) -> pang | dht:node_id().
ping(IP, Port) ->
    case gen_server:call(?MODULE, {request, ping, {IP, Port}}) of
        timeout -> pang;
        Values ->
            dht_bt_proto:decode_response(ping, Values)
    end.

%% @doc find_node/3 searches in the DHT for a given target NodeID
%% Search at the target IP/Port pair for the NodeID given by `Target'. May time out.
%% @end
-spec find_node(inet:ip_address(), inet:port_number(), dht:node_id()) ->
    {'error', 'timeout'} | {dht:node_id(), list(dht:node_t())}.
find_node(IP, Port, Target)  ->
    case gen_server:call(?MODULE, {request, {find_node, Target}, {IP, Port}}) of
        timeout ->
            {error, timeout};
        Values  ->
            {ID, Nodes} = dht_bt_proto:decode_response(find_node, Values),
            dht_state:notify({ID, IP, Port}, request_success),
            {ID, Nodes}
    end.

-spec get_peers(inet:ip_address(), inet:port_number(), infohash()) ->
    {dht:node_id(), token(), list(dht:peer_info()), list(dht:node_t())} | {error, any()}.
get_peers(IP, Port, InfoHash)  ->
    case gen_server:call(?MODULE, {request, {get_peers, InfoHash}, {IP, Port}}) of
        timeout ->
            {error, timeout};
        Values ->
            dht_bt_proto:decode_response(get_peers, Values)
    end.
    
-spec announce(SockName, Hash, Token, Port) -> {error, timeout} | dht:node_id()
  when
    SockName :: {inet:ip_address(), inet:port_number()},
    Hash :: infohash(),
    Token :: token(),
    Port :: inet:port_number().
announce({IP, Port}, InfoHash, Token, BTPort) ->
    Announce = {announce, {IP, Port}, InfoHash, Token, BTPort},
    case gen_server:call(?MODULE, Announce) of
        timeout -> {error, timeout};
        Values ->
            dht_bt_proto:decode_response(announce, Values)
    end.

-spec return({inet:ip_address(), inet:port_number()}, token(), list()) -> 'ok'.
return(Peer, ID, Response) ->
    ok = gen_server:call(?MODULE, {return, Peer, ID, Response}).

%% SEARCH API
%% ---------------------------------------------------

-spec find_node_search(dht:node_id()) -> list(dht:node_t()).
find_node_search(NodeID) ->
    Width = search_width(),
    dht_iter_search(
    	find_node,
    	NodeID,
    	Width,
    	search_retries(),
    	dht_state:closest_to(NodeID, Width)).

-spec find_node_search(dht:node_id(), list(dht:node_t())) -> list(dht:node_t()).
find_node_search(NodeID, Nodes) ->
    Width = search_width(),
    dht_iter_search(find_node, NodeID, Width, search_retries(), Nodes).

-spec get_peers_search(infohash()) ->
    {list(trackerinfo()), list(dht:peer_info()), list(dht:node_t())}.
get_peers_search(InfoHash) ->
    Width = search_width(),
    Nodes = dht_state:closest_to(InfoHash, Width), 
    dht_iter_search(get_peers, InfoHash, Width, search_retries(), Nodes).

-spec get_peers_search(infohash(), list(dht:node_t())) ->
    {list(trackerinfo()), list(dht:peer_info()), list(dht:node_t())}.
get_peers_search(InfoHash, Nodes) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(get_peers, InfoHash, Width, Retry, Nodes).


%% CALLBACKS
%% ---------------------------------------------------

init([DHTPort]) ->
    {ok, Socket} = gen_udp:open(DHTPort, socket_options()),
    erlang:send_after(?TOKEN_LIFETIME, self(), renew_token),
    {ok, #state{
    	socket=Socket, 
    	sent=gb_trees:empty(),
    	tokens= queue:from_list([random_token() || _ <- lists:seq(1, 3)])}}.

handle_call({request, Req, Peer}, From, State) ->
    send_query(Req, Peer, From, State);
handle_call({return, {IP, Port}, ID, Response}, _From, #state { socket = Socket } = State) ->
    Encoded = dht_bt_proto:encode_response(ID, Response),
    case gen_udp:send(Socket, IP, Port, Encoded) of
        ok -> ok;
        {error, einval} -> ok;
        {error, eagain} -> ok
    end,
    {reply, ok, State};
handle_call(node_port, _From, #state { socket = Socket } = State) ->
    {ok, SockName} = inet:sockname(Socket),
    {reply, SockName, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%
%% If a request times out, a timer will trigger.
%% Clean up the query and respond back to the caller when this happens.
%%
handle_info({request_timeout, _, Key}, #state{sent = Active} = State) ->
	case gb_trees:lookup(Key, Active) of
	    none -> {noreply, State};
	    {value, {Client, _Timeout}} ->
	        ok = gen_server:reply(Client, {error, timeout}),
	        {noreply, State#state { sent = gb_trees:delete(Key, Active) }}
	 end;
%%
%% Token renewal is called whenever the tokens grows too old.
%% Cycle the tokens to make sure they wither and die over time.
%%
handle_info(renew_token, #state { tokens = Tokens } = State) ->
    Cycled = queue:in(random_token(), queue:drop(Tokens)),
    erlang:send_after(?TOKEN_LIFETIME, self(), renew_token),
    {noreply, State#state { tokens = Cycled }};
%%
%% Handle an incoming UDP message on the socket
%%
handle_info({udp_passive, Socket}, #state { socket = Socket } = State) ->
	ok = inet:setopts(Socket, [{active, ?UDP_MAILBOX_SZ}]),
	{noreply, State};
handle_info({udp, _Socket, IP, Port, Packet}, #state{ sent = Sent, tokens = Tokens} = State) ->
    Self = dht_state:node_id(),  %% @todo cache this locally. It can't change.
    case view_packet_decode(Packet) of
        invalid_decode ->
        	{noreply, State};
        {valid_decode, ID, M} ->
        	Key = {{IP, Port}, ID},
        	case {gb_trees:lookup(Key, Sent), M} of
        	    {none, {response, _, _}} -> {noreply, State};
        	    {none, {error, _, _, _}} -> {noreply, State};
        	    {none, {Method, ID, Params}} ->
        	        %% Incoming request, handle it
        	        <<NodeID:160>> = benc:get_binary_value("id", Params),
        	        spawn_link( fun() -> dht_state:insert_node({NodeID, IP, Port}) end),
        	        spawn_link( fun() -> ?MODULE:handle_query(Method, Params, {IP, Port}, ID, Self, Tokens) end),
        	    	{noreply, State};
        	    {{value, {Client, TRef}}, _} ->
        	        %% The incoming message is a response for a request we sent out earlier
        	        _ = erlang:cancel_timer(TRef),
        	        handle_response(Client, M),
        	        {noreply, State#state { sent = gb_trees:delete(Key, Sent) }}
        	end
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% INTERNAL FUNCTIONS
%% ---------------------------------------------------

%% handle_response/2 handles correlated responses for processes using the `dht_net' framework.
handle_response(Client, {error, _ID, _Code, _ErrorMsg}) ->
	gen_server:reply(Client, timeout); %% @todo Return the error message here rather than quell it
handle_response(Client, {response, _ID, Values}) ->
	gen_server:reply(Client, Values);
handle_response(_Client, {_Method, _ID, _Values}) ->
	%% This triggers if we get a request in for something which is *already* in our list of Active (correlated) messages
	%% This can only happen if we send a message to ourselves, and we really shouldn't. Crash the system.
	exit(message_to_ourselves).

%% view_packet_decode/1 is a view on the validity of an incoming packet
view_packet_decode(Packet) ->
    try dht_bt_proto:decode_msg(Packet) of
        {error, ID, _Code, _ErrorMsg} = E -> {valid_decode, ID, E};
        {response, ID, _Values} = V -> {valid_decode, ID, V};
        {_Method, ID, _Params} = M -> {valid_decode, ID, M}
    catch
        _Class:_Error ->
            invalid_decode
    end.

gen_unique_message_id(Peer, Active) ->
    IntID = random:uniform(16#FFFF),
    MsgID = <<IntID:16>>,
    case gb_trees:is_defined({Peer, MsgID}, Active) of
        true ->
            %% That MsgID is already in use, recurse and try again
            gen_unique_message_id(Peer, Active);
        false -> MsgID
    end.

%
% Generate a random token value. A token value is used to filter out bogus announce
% requests, or at least announce requests from nodes that never sends get_peers requests.
%
random_token() ->
    ID0 = random:uniform(16#FFFF),
    ID1 = random:uniform(16#FFFF),
    <<ID0:16, ID1:16>>.

dht_iter_search(SearchType, Target, Width, Retry, Nodes)  ->
    WithDist = [{dht_metric:d(ID, Target), ID, IP, Port} || {ID, IP, Port} <- Nodes],
    dht_iter_search(SearchType, Target, Width, Retry, 0, WithDist,
                    gb_sets:empty(), gb_sets:empty(), []).

dht_iter_search(SearchType, _, _, Retry, Retry, _,
                _, Alive, WithPeers) ->
    TmpAlive  = gb_sets:to_list(Alive),
    AliveList = [{ID, IP, Port} || {_, ID, IP, Port} <- TmpAlive],
    case SearchType of
        find_node ->
            AliveList;
        get_peers ->
            Trackers = [{ID, IP, Port, Token}
                      ||{ID, IP, Port, Token, _} <- WithPeers],
            Peers = [Peer || {_, _, _, _, Peers} <- WithPeers, Peer <- Peers],
            {Trackers, Peers, AliveList}
    end;
dht_iter_search(SearchType, Target, Width, Retry, Retries,
                Next, Queried, Alive, WithPeers) ->

    % Mark all nodes in the queue as queried
    AddQueried = [{ID, IP, Port} || {_, ID, IP, Port} <- Next],
    NewQueried = gb_sets:union(Queried, gb_sets:from_list(AddQueried)),

    ThisNode = node(),
    Callback =
    case SearchType of
        find_node ->
            fun({_,_,IP,Port}) ->
                rpc:async_call(ThisNode, ?MODULE, find_node, [IP, Port, Target])
                end;
        get_peers ->
            fun({_,_,IP,Port}) ->
                rpc:async_call(ThisNode, ?MODULE, get_peers, [IP, Port, Target])
                end
    end,
    % Query all nodes in the queue and generate a list of
    % {Dist, ID, IP, Port, Nodes} elements
    Promises = lists:map(Callback, Next),
    ReturnValues = lists:map(fun rpc:yield/1, Promises),
    WithArgs = lists:zip(Next, ReturnValues),

    FailedCall = make_ref(),
    TmpSuccessful = [case {repack, SearchType, RetVal} of
        {repack, _, {badrpc, Reason}} ->
            ok = error_logger:error_msg("A RPC process crashed while sending a request ~p "
                        "to ~p:~p with reason ~p.",
                        [SearchType, IP, Port, Reason]),
            FailedCall;
        {repack, _, {error, timeout}} ->
            FailedCall;
        {repack, _, {error, response}} ->
            FailedCall;
        {repack, find_node, {NID, Nodes}} ->
            {{Dist, NID, IP, Port}, Nodes};
        {repack, get_peers, {NID, Token, Peers, Nodes}} ->
            {{Dist, NID, IP, Port}, {Token, Peers, Nodes}}
    end || {{Dist, _ID, IP, Port}, RetVal} <- WithArgs],
    Successful = [E || E <- TmpSuccessful, E =/= FailedCall],

    % Mark all nodes that responded as alive
    AddAlive = [N ||{{_, _, _, _}=N, _} <- Successful],
    NewAlive = gb_sets:union(Alive, gb_sets:from_list(AddAlive)),

    % Accumulate all nodes from the successful responses.
    % Calculate the relative distance to all of these nodes
    % and keep the closest nodes which has not already been
    % queried in a previous iteration
    NodeLists = [case {acc_nodes, {SearchType, Res}} of
        {acc_nodes, {find_node, Nodes}} ->
            Nodes;
        {acc_nodes, {get_peers, {_, _, Nodes}}} ->
            Nodes
    end || {_, Res} <- Successful],
    AllNodes  = lists:flatten(NodeLists),
    NewNodes  = [Node || Node <- AllNodes, not gb_sets:is_member(Node, NewQueried)],
    NewNext   = [{dht_metric:d(ID, Target), ID, IP, Port}
                || {ID, IP, Port} <- dht_metric:neighborhood(Target, NewNodes, Width)],

    % Check if the closest node in the work queue is closer
    % to the target than the closest responsive node that was
    % found in this iteration.
    MinAliveDist = case gb_sets:size(NewAlive) of
        0 ->
            infinity;
        _ ->
            {IMinAliveDist, _, _, _} = gb_sets:smallest(NewAlive),
            IMinAliveDist
    end,

    MinQueueDist = case NewNext of
        [] ->
            infinity;
        Other ->
            {MinDist, _, _, _} = lists:min(Other),
            MinDist
    end,

    % Check if the closest node in the work queue is closer
    % to the infohash than the closest responsive node.
    NewRetries = if
        (MinQueueDist <  MinAliveDist) -> 0;
        (MinQueueDist >= MinAliveDist) -> Retries + 1
    end,

    % Accumulate the trackers and peers found if this is a get_peers search.
    NewWithPeers = case SearchType of
        find_node -> []=WithPeers;
        get_peers ->
            Tmp=[{ID, IP, Port, Token, Peers}
                || {{_, ID, IP, Port}, {Token, Peers, _}} <- Successful, Peers > []],
            WithPeers ++ Tmp
    end,

    NewNext2 = lists:usort(NewNext),
    dht_iter_search(SearchType, Target, Width, Retry, NewRetries,
                    NewNext2, NewQueried, NewAlive, NewWithPeers).

send_query(QueryData, {IP, Port} = Peer, From, #state { sent = Active, socket = Socket } = State) ->
    MsgID = gen_unique_message_id(Peer, Active),
    Query = dht_bt_proto:encode_query(QueryData, MsgID),
    Key = {Peer, MsgID},

    case gen_udp:send(Socket, IP, Port, Query) of
        ok ->
            TRef = erlang:send_after(query_timeout(), self(), {request_timeout, self(), {Peer, MsgID}}),
            Value = {From, TRef},
            {noreply, State#state { sent = gb_trees:insert(Key, Value, Active) }};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

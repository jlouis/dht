%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc TODO
%% @end
-module(dht_net).

-behaviour(gen_server).

%
% Implementation notes
%     RPC calls to remote nodes in the DHT are exposed to
%     clients using the gen_server call mechanism. In order
%     to make this work the client reference passed to the
%     handle_call/3 callback is stored in the server state.
%
%     When a response is received from the remote node, the
%     source IP and port combined with the message id is used
%     to map the response to the correct client reference.
%
%     A timer is used to notify the server of requests that
%     time out, if a request times out {error, timeout} is
%     returned to the client. If a response is received after
%     the timer has fired, the response is dropped.
%
%     The expected behavior is that the high-level timeout fires
%     before the gen_server call times out, therefore this interval
%     should be shorter then the interval used by gen_server calls.
%
%     The find_node_search/1 and get_peers_search/1 functions
%     are almost identical, they both recursively search for the
%     nodes closest to an id. The difference is that get_peers should
%     return as soon as it finds a node that acts as a tracker for
%     the infohash.

% Public interface
-export([start_link/1,
         node_port/0,
         ping/2,
         find_node/3,
         find_node_search/1,
         find_node_search/2,
         get_peers/3,
         get_peers_search/1,
         get_peers_search/2,
         announce/5,
         return/4]).

-type nodeinfo() :: etorrent_types:nodeinfo().
-type peerinfo() :: etorrent_types:peerinfo().
-type trackerinfo() :: etorrent_types:trackerinfo().
-type infohash() :: etorrent_types:infohash().
-type token() :: etorrent_types:token().
-type dht_qtype() :: etorrent_types:dht_qtype().
-type ipaddr() :: etorrent_types:ipaddr().
-type nodeid() :: etorrent_types:nodeid().
-type portnum() :: etorrent_types:portnum().
-type transaction() :: etorrent_types:transaction().

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports
-export([handle_query/7,
         decode_msg/1]).


-record(state, {
    socket :: inet:socket(),
    sent   :: gb_trees:tree(),
    tokens :: queue:queue()
}).

%
% Type definitions and function specifications
%


%
% Contansts and settings
%
srv_name() ->
   dht_socket_server.

query_timeout() ->
    2000.

search_width() ->
    32.

search_retries() ->
    4.

socket_options() ->
    [list, inet, {active, true}]
    ++ case etorrent_config:listen_ip() of all -> []; IP -> [{ip, IP}] end.

token_lifetime() ->
    5*60*1000.

%
% Public interface
%
start_link(DHTPort) ->
    gen_server:start_link({local, srv_name()}, ?MODULE, [DHTPort], []).

-spec node_port() -> portnum().
node_port() ->
    gen_server:call(srv_name(), {get_node_port}).


%
%
%
-spec ping(ipaddr(), portnum()) -> pang | nodeid().
ping(IP, Port) ->
    case gen_server:call(srv_name(), {ping, IP, Port}) of
        timeout -> pang;
        Values ->
            _ID = decode_response(ping, Values)
    end.

%
%
%
-spec find_node(ipaddr(), portnum(), nodeid()) ->
    {'error', 'timeout'} | {nodeid(), list(nodeinfo())}.
find_node(IP, Port, Target)  ->
    case gen_server:call(srv_name(), {find_node, IP, Port, Target}) of
        timeout ->
            {error, timeout};
        Values  ->
            {ID, Nodes} = decode_response(find_node, Values),
            dht_state:log_request_success(ID, IP, Port),
            {ID, Nodes}
    end.

%
%
%
-spec get_peers(ipaddr(), portnum(), infohash()) ->
    {nodeid(), token(), list(peerinfo()), list(nodeinfo())} | {error, any()}.
get_peers(IP, Port, InfoHash)  ->
    Call = {get_peers, IP, Port, InfoHash},
    case gen_server:call(srv_name(), Call) of
        timeout ->
            {error, timeout};
        Values ->
            decode_response(get_peers, Values)
    end.

%
% Recursively search for the 100 nodes that are the closest to
% the local DHT node.
%
% Keep tabs on:
%     - Which nodes has been queried?
%     - Which nodes has responded?
%     - Which nodes has not been queried?
% FIXME: It returns `[{649262719799963483759422800960489108797112648079,{127,0,0,2},1743},{badrpc,{127,0,0,4},1763}]'.
-spec find_node_search(nodeid()) -> list(nodeinfo()).
find_node_search(NodeID) ->
    Width = search_width(),
    Retry = search_retries(),
    Nodes = dht_state:closest_to(NodeID, Width),
    dht_iter_search(find_node, NodeID, Width, Retry, Nodes).

-spec find_node_search(nodeid(), list(nodeinfo())) -> list(nodeinfo()).
find_node_search(NodeID, Nodes) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(find_node, NodeID, Width, Retry, Nodes).

-spec get_peers_search(infohash()) ->
    {list(trackerinfo()), list(peerinfo()), list(nodeinfo())}.
get_peers_search(InfoHash) ->
    Width = search_width(),
    Retry = search_retries(),
    Nodes = dht_state:closest_to(InfoHash, Width), 
    dht_iter_search(get_peers, InfoHash, Width, Retry, Nodes).

-spec get_peers_search(infohash(), list(nodeinfo())) ->
    {list(trackerinfo()), list(peerinfo()), list(nodeinfo())}.
get_peers_search(InfoHash, Nodes) ->
    Width = search_width(),
    Retry = search_retries(),
    dht_iter_search(get_peers, InfoHash, Width, Retry, Nodes).
    

dht_iter_search(SearchType, Target, Width, Retry, Nodes)  ->
    WithDist = [{dht:distance(ID, Target), ID, IP, Port} || {ID, IP, Port} <- Nodes],
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
            ok = lager:error("A RPC process crashed while sending a request ~p "
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
    NewNext   = [{dht:distance(ID, Target), ID, IP, Port}
                ||{ID, IP, Port} <- dht:closest_to(Target, NewNodes, Width)],

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


%
%
%
-spec announce(ipaddr(), portnum(), infohash(), token(), portnum()) ->
    {'error', 'timeout'} | nodeid().
announce(IP, Port, InfoHash, Token, BTPort) ->
    Announce = {announce, IP, Port, InfoHash, Token, BTPort},
    case gen_server:call(srv_name(), Announce) of
        timeout -> {error, timeout};
        Values ->
            decode_response(announce, Values)
    end.

%
%
%
-spec return(ipaddr(), portnum(), transaction(), list()) -> 'ok'.
return(IP, Port, ID, Response) ->
    ok = gen_server:call(srv_name(), {return, IP, Port, ID, Response}).

init([DHTPort]) ->
    {ok, Socket} = gen_udp:open(DHTPort, socket_options()),
    State = #state{socket=Socket,
                   sent=gb_trees:empty(),
                   tokens=init_tokens(3)},
    erlang:send_after(token_lifetime(), self(), renew_token),
    {ok, State}.



timeout_reference(IP, Port, ID) ->
    Msg = {timeout, self(), IP, Port, ID},
    erlang:send_after(query_timeout(), self(), Msg).

cancel_timeout(TimeoutRef) ->
    erlang:cancel_timer(TimeoutRef).

handle_call({ping, IP, Port}, From, State) ->
    Args = common_values(),
    do_send_query('ping', Args, IP, Port, From, State);

handle_call({find_node, IP, Port, Target}, From, State) ->
    LTarget = dht:list_id(Target),
    Args = [{<<"target">>, list_to_binary(LTarget)} | common_values()],
    do_send_query('find_node', Args, IP, Port, From, State);

handle_call({get_peers, IP, Port, InfoHash}, From, State) ->
    LHash = list_to_binary(dht:list_id(InfoHash)),
    Args  = [{<<"info_hash">>, LHash}| common_values()],
    ok = lager:debug("Send get_peers to ~p:~p for ~s.",
                [IP, Port, integer_hash_to_literal(InfoHash)]),
    do_send_query('get_peers', Args, IP, Port, From, State);

handle_call({announce, IP, Port, InfoHash, Token, BTPort}, From, State) ->
    LHash = list_to_binary(dht:list_id(InfoHash)),
    Args = [
        {<<"info_hash">>, LHash},
        {<<"port">>, BTPort},
        {<<"token">>, Token} | common_values()],
    do_send_query('announce', Args, IP, Port, From, State);

handle_call({return, IP, Port, ID, Values}, _From, State) ->
    Socket = State#state.socket,
    Response = encode_response(ID, Values),
    ok = case gen_udp:send(Socket, IP, Port, Response) of
        ok ->
            ok;
        {error, einval} ->
            ok = lager:error("Error (einval) when returning to ~w:~w", [IP, Port]),
            ok;
        {error, eagain} ->
            ok = lager:error("Error (eagain) when returning to ~w:~w", [IP, Port]),
            ok
    end,
    {reply, ok, State};

handle_call({get_node_port}, _From, State) ->
    #state{
        socket=Socket} = State,
    {ok, {_, Port}} = inet:sockname(Socket),
    {reply, Port, State};

handle_call({get_num_open}, _From, State) ->
    Sent = State#state.sent,
    NumSent = gb_trees:size(Sent),
    {reply, NumSent, State}.

do_send_query(Method, Args, IP, Port, From, State) ->
    #state{sent=Sent,
           socket=Socket} = State,
    ok = lager:info("Sending ~w to ~w:~w", [Method, IP, Port]),

    MsgID = unique_message_id(IP, Port, Sent),
    Query = encode_query(Method, MsgID, Args),

    case gen_udp:send(Socket, IP, Port, Query) of
        ok ->
            TRef = timeout_reference(IP, Port, MsgID),
            ok = lager:info("Sent ~w to ~w:~w", [Method, IP, Port]),

            NewSent = store_sent_query(IP, Port, MsgID, From, TRef, Sent),
            NewState = State#state{sent=NewSent},
            {noreply, NewState};
        {error, einval} ->
            ok = lager:error("Error (einval) when sending ~w to ~w:~w", [Method, IP, Port]),
            {reply, timeout, State};
        {error, eagain} ->
            ok = lager:error("Error (eagain) when sending ~w to ~w:~w", [Method, IP, Port]),
            {reply, timeout, State}
    end.

handle_cast(not_implemented, State) ->
    {noreply, State}.

handle_info({timeout, _, IP, Port, ID}, State) ->
    #state{sent=Sent} = State,

    NewState = case find_sent_query(IP, Port, ID, Sent) of
        error ->
            State;
        {ok, {Client, _Timeout}} ->
            _ = gen_server:reply(Client, timeout),
            NewSent = clear_sent_query(IP, Port, ID, Sent),
            State#state{sent=NewSent}
    end,
    {noreply, NewState};

handle_info(renew_token, State) ->
    #state{tokens=PrevTokens} = State,
    NewTokens = renew_token(PrevTokens),
    NewState = State#state{tokens=NewTokens},
    erlang:send_after(token_lifetime(), self(), renew_token),
    {noreply, NewState};

handle_info({udp, _Socket, IP, Port, Packet}, State) ->
    #state{
        sent=Sent,
        tokens=Tokens} = State,
    Self = dht_state:node_id(),
    NewState = case (catch decode_msg(Packet)) of
        {'EXIT', _} ->
            ok = lager:error("Invalid packet from ~w:~w: ~w", [IP, Port, Packet]),
            State;

        {error, ID, Code, ErrorMsg} ->
            ok = lager:error("Received error from ~w:~w (~w) ~w", [IP, Port, Code, ErrorMsg]),
            case find_sent_query(IP, Port, ID, Sent) of
                error ->
                    State;
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, timeout),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent}
            end;

        {response, ID, Values} ->
            case find_sent_query(IP, Port, ID, Sent) of
                error ->
                    State;
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, Values),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent}
            end;
        {Method, ID, Params} ->
            ok = lager:info("Received ~w from ~w:~w", [Method, IP, Port]),
            case find_sent_query(IP, Port, ID, Sent) of
                {ok, {Client, Timeout}} ->
                    _ = cancel_timeout(Timeout),
                    _ = gen_server:reply(Client, timeout),
                    ok = lager:error("Bad node, don't send queries to yourself!"),
                    NewSent = clear_sent_query(IP, Port, ID, Sent),
                    State#state{sent=NewSent};
                error ->
                    %% Handle request.
                    SNID = get_string("id", Params),
                    NID = dht:integer_id(SNID),
                    spawn_link(dht_state, safe_insert_node, [NID, IP, Port]),
                    HandlerArgs = [Method, Params, IP, Port, ID, Self, Tokens],
                    spawn_link(?MODULE, handle_query, HandlerArgs),
                    State
            end
    end,
    {noreply, NewState};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% Default args. Returns a proplist of default args
common_values() ->
    Self = dht_state:node_id(),
    common_values(Self).

common_values(Self) ->
    LSelf = dht:list_id(Self),
    [{<<"id">>, list_to_binary(LSelf)}].

-spec handle_query(dht_qtype(), etorrent_types:bcode(), ipaddr(),
                  portnum(), transaction(), nodeid(), _) -> 'ok'.

handle_query('ping', _, IP, Port, MsgID, Self, _Tokens) ->
    return(IP, Port, MsgID, common_values(Self));

handle_query('find_node', Params, IP, Port, MsgID, Self, _Tokens) ->
    Target = dht:integer_id(benc:get_value(<<"target">>, Params)),
    CloseNodes = filter_node(IP, Port, dht_state:closest_to(Target)),
    BinCompact = node_infos_to_compact(CloseNodes),
    Values = [{<<"nodes">>, BinCompact}],
    return(IP, Port, MsgID, common_values(Self) ++ Values);

handle_query('get_peers', Params, IP, Port, MsgID, Self, Tokens) ->
    InfoHash = dht:integer_id(benc:get_value(<<"info_hash">>, Params)),
    ok = lager:debug("Take request get_peers from ~p:~p for ~s.",
                [IP, Port, integer_hash_to_literal(InfoHash)]),
    %% TODO: handle non-local requests.
    Values = case dht_tracker:get_peers(InfoHash) of
        [] ->
            Nodes = filter_node(IP, Port, dht_state:closest_to(InfoHash)),
            BinCompact = node_infos_to_compact(Nodes),
            [{<<"nodes">>, BinCompact}];
        Peers ->
            ok = lager:debug("Get a list of peers from the local tracker ~p", [Peers]),
            PeerList = [peers_to_compact([P]) || P <- Peers],
            [{<<"values">>, PeerList}]
    end,
    Token = [{<<"token">>, token_value(IP, Port, Tokens)}],
    return(IP, Port, MsgID, common_values(Self) ++ Token ++ Values);

handle_query('announce', Params, IP, Port, MsgID, Self, Tokens) ->
    InfoHash = dht:integer_id(benc:get_value(<<"info_hash">>, Params)),
    ok = lager:info("Announce from ~p:~p for ~s~n",
                [IP, Port, integer_hash_to_literal(InfoHash)]),
    BTPort = benc:get_value(<<"port">>,   Params),
    Token = get_string(<<"token">>, Params),
    case is_valid_token(Token, IP, Port, Tokens) of
        true ->
            %% TODO: handle non-local requests.
            dht_tracker:announce(InfoHash, IP, BTPort);
        false ->
            FmtArgs = [IP, Port, Token],
            lager:error("Invalid token from ~w:~w ~w", FmtArgs)
    end,
    return(IP, Port, MsgID, common_values(Self)).

unique_message_id(IP, Port, Open) ->
    IntID = random:uniform(16#FFFF),
    MsgID = <<IntID:16>>,
    IsLocal  = gb_trees:is_defined(tkey(IP, Port, MsgID), Open),
    if IsLocal -> unique_message_id(IP, Port, Open);
       true    -> MsgID
    end.

store_sent_query(IP, Port, ID, Client, Timeout, Open) ->
    K = tkey(IP, Port, ID),
    V = tval(Client, Timeout),
    gb_trees:insert(K, V, Open).

find_sent_query(IP, Port, ID, Open) ->
    case gb_trees:lookup(tkey(IP, Port, ID), Open) of
       none -> error;
       {value, Value} -> {ok, Value}
    end.

clear_sent_query(IP, Port, ID, Open) ->
    gb_trees:delete(tkey(IP, Port, ID), Open).

tkey(IP, Port, ID) ->
   {IP, Port, ID}.

tval(Client, TimeoutRef) ->
    {Client, TimeoutRef}.

get_string(What, PL) ->
    benc:get_binary_value(What, PL).

%
% Generate a random token value. A token value is used to filter out bogus announce
% requests, or at least announce requests from nodes that never sends get_peers requests.
%
random_token() ->
    ID0 = random:uniform(16#FFFF),
    ID1 = random:uniform(16#FFFF),
    <<ID0:16, ID1:16>>.

%
% Initialize the socket server's token queue, the size of this queue
% will be kept constant during the running-time of the server. The
% size of this queue specifies how old tokens the server will accept.
%
init_tokens(NumTokens) ->
    queue:from_list([random_token() || _ <- lists:seq(1, NumTokens)]).
%
% Calculate the token value for a client based on the client's IP address
% and Port number combined with a secret token value held by the socket server.
% This avoids the need to store unique token values in the socket server.
%
token_value(IP, Port, Token) when is_binary(Token) ->
    Hash = erlang:phash2({IP, Port, Token}),
    <<Hash:32>>;

token_value(IP, Port, Tokens) ->
    MostRecent = queue:last(Tokens),
    token_value(IP, Port, MostRecent).



%
% Check if a token value included by a node in an announce message is bogus
% (based on a token that is not recent enough).
%
is_valid_token(TokenValue, IP, Port, Tokens) ->
    ValidValues = [token_value(IP, Port, Token) || Token <- queue:to_list(Tokens)],
    lists:member(TokenValue, ValidValues).

%
% Discard the oldest token and create a new one to replace it.
%
renew_token(Tokens) ->
    {_, WithoutOldest} = queue:out(Tokens),
    queue:in(random_token(), WithoutOldest).



decode_msg(InMsg) ->
    {ok, Msg} = benc:decode(InMsg),
    MsgID = benc:get_value(<<"t">>, Msg),
    case benc:get_value(<<"y">>, Msg) of
        <<"q">> ->
            MString = benc:get_value(<<"q">>, Msg),
            Method  = string_to_method(MString),
            Params  = benc:get_value(<<"a">>, Msg),
            {Method, MsgID, Params};
        <<"r">> ->
            Values = benc:get_value(<<"r">>, Msg),
            {response, MsgID, Values};
        <<"e">> ->
            [ECode, EMsg] = benc:get_value(<<"e">>, Msg),
            {error, MsgID, ECode, EMsg}
    end.

decode_response(ping, Values) ->
     dht:integer_id(benc:get_value(<<"id">>, Values));
decode_response(find_node, Values) ->
    ID = dht:integer_id(benc:get_value(<<"id">>, Values)),
    BinNodes = benc:get_value(<<"nodes">>, Values),
    Nodes = compact_to_node_infos(BinNodes),
    {ID, Nodes};
decode_response(get_peers, Values) ->
    ID = dht:integer_id(benc:get_value(<<"id">>, Values)),
    Token = benc:get_value(<<"token">>, Values),
    NoPeers = make_ref(),
    MaybePeers = benc:get_value(<<"values">>, Values, NoPeers),
    {Peers, Nodes} = case MaybePeers of
        NoPeers when is_reference(NoPeers) ->
            BinCompact = benc:get_value(<<"nodes">>, Values),
            INodes = compact_to_node_infos(BinCompact),
            {[], INodes};
        BinPeers when is_list(BinPeers) ->
            PeerLists = [compact_to_peers(N) || N <- BinPeers],
            IPeers = lists:flatten(PeerLists),
            {IPeers, []}
    end,
    {ID, Token, Peers, Nodes};
decode_response(announce, Values) ->
    dht:integer_id(benc:get_value(<<"id">>, Values)).



encode_query(Method, MsgID, Params) ->
    Msg = [
       {<<"y">>, <<"q">>},
       {<<"q">>, method_to_string(Method)},
       {<<"t">>, MsgID},
       {<<"a">>, Params}],
    benc:encode(Msg).

encode_response(MsgID, Values) ->
    Msg = [
       {<<"y">>, <<"r">>},
       {<<"t">>, MsgID},
       {<<"r">>, Values}],
    benc:encode(Msg).

method_to_string(ping) -> <<"ping">>;
method_to_string(find_node) -> <<"find_node">>;
method_to_string(get_peers) -> <<"get_peers">>;
method_to_string(announce) -> <<"announce_peer">>.

string_to_method(<<"ping">>) -> ping;
string_to_method(<<"find_node">>) -> find_node;
string_to_method(<<"get_peers">>) -> get_peers;
string_to_method(<<"announce_peer">>) -> announce.



compact_to_peers(<<>>) ->
    [];
compact_to_peers(<<A0, A1, A2, A3, Port:16, Rest/binary>>) ->
    Addr = {A0, A1, A2, A3},
    [{Addr, Port}|compact_to_peers(Rest)].

peers_to_compact(PeerList) ->
    peers_to_compact(PeerList, <<>>).
peers_to_compact([], Acc) ->
    Acc;
peers_to_compact([{{A0, A1, A2, A3}, Port}|T], Acc) ->
    CPeer = <<A0, A1, A2, A3, Port:16>>,
    peers_to_compact(T, <<Acc/binary, CPeer/binary>>).

compact_to_node_infos(<<>>) ->
    [];
compact_to_node_infos(<<ID:160, A0, A1, A2, A3,
                        Port:16, Rest/binary>>) ->
    IP = {A0, A1, A2, A3},
    NodeInfo = {ID, IP, Port},
    [NodeInfo|compact_to_node_infos(Rest)].

node_infos_to_compact(NodeList) ->
    node_infos_to_compact(NodeList, <<>>).
node_infos_to_compact([], Acc) ->
    Acc;
node_infos_to_compact([{ID, {A0, A1, A2, A3}, Port}|T], Acc) ->
    CNode = <<ID:160, A0, A1, A2, A3, Port:16>>,
    node_infos_to_compact(T, <<Acc/binary, CNode/binary>>).


integer_hash_to_literal(InfoHashInt) when is_integer(InfoHashInt) ->
    io_lib:format("~40.16.0B", [InfoHashInt]).


%% @doc Delete node with `IP' and `Port' from the list.
filter_node(IP, Port, Nodes) ->
    [X || {_NID, NIP, NPort}=X <- Nodes, NIP =/= IP orelse NPort =/= Port].


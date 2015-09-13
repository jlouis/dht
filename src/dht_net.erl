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
%% Lifetime interface. Mostly has to do with setup and configuration
-export([start_link/1, start_link/2, node_port/0]).

%% DHT API
-export([
         store/4,
         find_node/2,
         find_value/2,
         ping/1,
         ping_verify/3
]).

%% Private internal use
-export([handle_query/5]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

% internal exports
-export([sync/0]).

-record(state, {
    socket :: inet:socket(),
    outstanding :: #{ {dht:peer(), binary()} => {pid(), reference()} },
    tokens :: queue:queue()
}).

%
% Constants and settings
%
-define(TOKEN_LIFETIME, 5 * 60 * 1000).
-define(UDP_MAILBOX_SZ, 16).
-define(QUERY_TIMEOUT, 2000).

%
% Public interface
%

%% @doc Start up the DHT networking subsystem
%% @end
start_link(DHTPort) ->
    start_link(DHTPort, #{}).
    
%% @private
start_link(Port, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port, Opts], []).

%% @doc node_port/0 returns the (UDP) port number to which the DHT system is bound.
%% @end
-spec node_port() -> {inet:ip_address(), inet:port_number()}.
node_port() ->
    gen_server:call(?MODULE, node_port).

%% @private
request(Target, Q) ->
    gen_server:call(?MODULE, {request, Target, Q}).

%% @private
sync() ->
    gen_server:call(?MODULE, sync).

%% @doc ping/2 sends a ping to a node
%% Calling `ping(IP, Port)' will send a ping message to the IP/Port pair
%% and wait for a result to come back. Used to check if the node in the
%% other end is up and running.
%%
%% If running over an IP/Port pair, we can't timeout, so we don't
%% timeout the peer here. We do that in dht_state.
%% @end
-spec ping({inet:ip_address(), inet:port_number()}) ->
      pang | {ok, dht:node_id(), benc:t()} | {error, Reason}
  when Reason :: term().
ping(Peer) ->
    case request(Peer, ping) of
        {error, timeout} -> pang;
        {response, _, ID, ping} -> {ok, ID};
        {error, eagain} ->
            timer:sleep(15),
            ping(Peer);
        {error, Reason} ->
            fail = error_common(Reason),
            pang
    end.

ping_verify(Node, VNode, Opts) ->
    gen_server:cast(?MODULE, {ping_verify, VNode, {Node, Opts}}).

%% @doc find_node/3 searches in the DHT for a given target NodeID
%% Search at the target IP/Port pair for the NodeID given by `Target'. May time out.
%% @end
-spec find_node({IP, Port}, Target) -> {ID, Nodes} | {error, Reason}
  when
    IP :: dht:ip_address(),
    Port :: dht:port(),
    Target :: dht:node_id(),
    ID :: dht:node_id(),
    Nodes :: [dht:node_t()],
    Reason :: any().

find_node({IP, Port}, N)  ->
    case request({IP, Port}, {find, node, N}) of
        {error, E} -> {error, E};
        {response, _, _, {find, node, Token, Nodes}} ->
            {nodes, N, Token, Nodes}
    end.

-spec find_value(Peer, ID) ->
			  {nodes, ID, [Node]}
		    | {values, ID, Token, [Value]}
		    | {error, Reason}
	when
	  Peer :: {inet:ip_address(), inet:port_number()},
	  ID :: dht:id(),
	  Node :: dht:node_t(),
	  Token :: dht:token(),
	  Value :: dht:node_t(),
	  Reason :: any().
	    
find_value(Peer, IDKey)  ->
    case request(Peer, {find, value, IDKey}) of
        {error, Reason} -> {error, Reason};
        {response, _, ID, {find, node, Token, Nodes}} ->
            {nodes, ID, Token, Nodes};
        {response, _, ID, {find, value, Token, Values}} ->
            {values, ID, Token, Values}
    end.

-spec store(Peer, Token, ID, Port) -> {error, timeout} | dht:node_id()
  when
    Peer :: {inet:ip_address(), inet:port_number()},
    ID :: dht:id(),
    Token :: dht:token(),
    Port :: inet:port_number().

store(Peer, Token, IDKey, Port) ->
    case request(Peer, {store, Token, IDKey, Port}) of
        {error, R} -> {error, R};
        {response, _, ID, _} ->
            {ok, ID}
    end.

%% @private
handle_query(ping, Peer, Tag, OwnID, _Tokens) ->
    return(Peer, {response, Tag, OwnID, ping});
handle_query({find, node, ID}, Peer, Tag, OwnID, Tokens) ->
    TVal = token_value(Peer, queue:last(Tokens)),
    Nodes = filter_node(Peer, dht_state:closest_to(ID)),
    return(Peer, {response, Tag, OwnID, {find, node, TVal, Nodes}});
handle_query({find, value, ID}, Peer, Tag, OwnID, Tokens) ->
    case dht_store:find(ID) of
        [] ->
            handle_query({find, node, ID}, Peer, Tag, OwnID, Tokens);
        Peers ->
            TVal = token_value(Peer, queue:last(Tokens)),
            return(Peer, {response, Tag, OwnID, {find, value, TVal, Peers}})
    end;
handle_query({store, Token, ID, Port}, {IP, _Port} = Peer, Tag, OwnID, Tokens) ->
    case is_valid_token(Token, Peer, Tokens) of
        false -> ok;
        true -> dht_store:store(ID, {IP, Port})
    end,
    return(Peer, {response, Tag, OwnID, store}).

-spec return({inet:ip_address(), inet:port_number()}, any()) -> 'ok'.
return(Peer, Response) ->
    case gen_server:call(?MODULE, {return, Peer, Response}) of
        ok -> ok;
        {error, eagain} ->
            %% For now, we just ignore the case where EAGAIN happens
            %% in the system, but we could return these packets back
            %% to the caller by trying again. lager:warning("return
            %% packet to peer responded with EAGAIN"),
            {error, eagain};
        {error, Reason} ->
            fail = error_common(Reason),
            {error, Reason}
    end.

%% CALLBACKS
%% ---------------------------------------------------

%% @private
init([DHTPort, Opts]) ->
    {ok, Base} = application:get_env(dht, listen_opts),
    {ok, Socket} = dht_socket:open(DHTPort, [binary, inet, {active, ?UDP_MAILBOX_SZ} | Base]),
    dht_time:send_after(?TOKEN_LIFETIME, ?MODULE, renew_token),
    {ok, #state{
    	socket = Socket, 
    	outstanding = #{},
    	tokens = init_tokens(Opts)}}.

init_tokens(#{ tokens := Toks}) -> queue:from_list(Toks);
init_tokens(#{}) -> queue:from_list([random_token() || _ <- lists:seq(1, 2)]).

%% @private
handle_call({request, Peer, Request}, From, State) ->
    case send_query(Peer, Request, From, State) of
        {ok, S} -> {noreply, S};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({return, {IP, Port}, Response}, _From, #state { socket = Socket } = State) ->
    Packet = dht_proto:encode(Response),
    Result = dht_socket:send(Socket, IP, Port, Packet),
    {reply, Result, State};
handle_call(sync, _From, #state{} = State) ->
    {reply, ok, State};
handle_call(node_port, _From, #state { socket = Socket } = State) ->
    {ok, SockName} = dht_socket:sockname(Socket),
    {reply, SockName, State}.

%% @private
handle_cast({ping_verify, VNode, {Node, Opts}}, State) ->
    case send_query(VNode, ping, {ping_verify, VNode, Node, Opts}, State) of
        {ok, S} -> {noreply, S};
        {error, Reason} ->
            error_logger:error_report([unexpected, {error, Reason}]),
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({request_timeout, Key}, State) ->
    HandledState = handle_request_timeout(Key, State),
    {noreply, HandledState};
handle_info(renew_token, State) ->
    dht_time:send_after(?TOKEN_LIFETIME, self(), renew_token),
    {noreply, handle_recycle_token(State)};
handle_info({udp_passive, Socket}, #state { socket = Socket } = State) ->
	ok = inet:setopts(Socket, [{active, ?UDP_MAILBOX_SZ}]),
	{noreply, State};
handle_info({udp, _Socket, IP, Port, Packet}, State) when is_binary(Packet) ->
    {noreply, handle_packet({IP, Port}, Packet, State)};
handle_info({stop, Caller}, #state{} = State) ->
    Caller ! stopped,
    {stop, normal, State};
handle_info(Msg, State) ->
    error_logger:error_msg("Unkown message in handle info: ~p", [Msg]),
    {noreply, State}.

%% @private
terminate(_, _State) ->
    ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

%% INTERNAL FUNCTIONS
%% ---------------------------------------------------

%% Handle a request timeout by unblocking the calling process with `{error, timeout}'
handle_request_timeout(Key, #state { outstanding = Outstanding } = State) ->
    case maps:get(Key, Outstanding, not_found) of
        not_found -> State;
        {Client, _Timeout} ->
            reply(Client, {error, timeout}),
            gen_server:reply(Client, {error, timeout}),
            State#state { outstanding = maps:remove(Key, Outstanding) }
    end.

%% reply/2 handles correlated responses for processes using the `dht_net' framework.
reply({ping_verify, VNode, Node, Opts}, {error, timeout}) ->
    dht_state:request_timeout(VNode),
    dht_state:request_success(Node, Opts),
    ok;
reply({ping_verify, _VNode, Node, Opts}, {response, _, _, ping}) ->
    dht_state:request_success(Node, Opts),
    ok;
reply(_Client, {query, _, _, _} = M) -> exit({message_to_ourselves, M});
reply({P, T} = From, M) when is_pid(P), is_reference(T) ->
    gen_server:reply(From, M).

%%
%% Token renewal is called whenever the tokens grows too old.
%% Cycle the tokens to make sure they wither and die over time.
%%
handle_recycle_token(#state { tokens = Tokens } = State) ->
    Cycled = queue:in(random_token(), queue:drop(Tokens)),
    State#state { tokens = Cycled }.

%%
%% Handle an incoming UDP message on the socket
%%
handle_packet({IP, Port} = Peer, Packet,
              #state { outstanding = Outstanding, tokens = Tokens } = State) ->
    Self = dht_state:node_id(), %% @todo cache this locally. It can't change.
    case view_packet_decode(Packet) of
        invalid_decode ->
            State;
        {valid_decode, PeerID, Tag, M} ->
            Key = {Peer, Tag},
            case maps:get(Key, Outstanding, not_found) of
              not_found ->
                case M of
                    {query, Tag, PeerID, Query} ->
                      %% Incoming request
                      dht_state:request_success({PeerID, IP, Port}, #{ reachable => false }),
                      spawn_link(fun() -> ?MODULE:handle_query(Query, Peer, Tag, Self, Tokens) end),
                      State;
                    _ ->
                      State %% No recipient
                end;
              {Client, TRef} ->
                %% Handle blocked client process
                dht_time:cancel_timer(TRef),
                dht_state:request_success({PeerID, IP, Port}, #{ reachable => true }),
                reply(Client, M),
                State#state { outstanding = maps:remove(Key, Outstanding) }
            end
    end.



%% view_packet_decode/1 is a view on the validity of an incoming packet
view_packet_decode(Packet) ->
    try dht_proto:decode(Packet) of
        {error, {old_version, <<0,0,0,0,0,0,0,0>>}} -> invalid_decode;
        {error, Tag, ID, _Code, _Msg} = E -> {valid_decode, ID, Tag, E};
        {response, Tag, ID, _Reply} = R -> {valid_decode, ID, Tag, R};
        {query, Tag, ID, _Query} = Q -> {valid_decode, ID, Tag, Q}
    catch
       _Class:_Error ->
           invalid_decode
    end.

unique_message_id(Peer, Active) ->
    unique_message_id(Peer, Active, 16).
	
unique_message_id(Peer, Active, K) when K > 0 ->
    IntID = dht_rand:uniform(16#FFFF),
    MsgID = <<IntID:16>>,
    case maps:is_key({Peer, MsgID}, Active) of
        true ->
            %% That MsgID is already in use, recurse and try again
            unique_message_id(Peer, Active, K-1);
        false -> MsgID
    end.

%
% Generate a random token value. A token value is used to filter out bogus store
% requests, or at least store requests from nodes that never sends find_value requests.
%
random_token() ->
    dht_rand:crypto_rand_bytes(16).

send_query({IP, Port} = Peer, Query, From, #state { outstanding = Active, socket = Socket } = State) ->
    Self = dht_state:node_id(), %% @todo cache this locally. It can't change.
    MsgID = unique_message_id(Peer, Active),
    Packet = dht_proto:encode({query, MsgID, Self, Query}),

    case dht_socket:send(Socket, IP, Port, Packet) of
        ok ->
            TRef = dht_time:send_after(?QUERY_TIMEOUT, dht_net, {request_timeout, {Peer, MsgID}}),

            Key = {Peer, MsgID},
            Value = {From, TRef},
            {ok, State#state { outstanding = Active#{ Key => Value } } };
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Delete node with `IP' and `Port' from the list.
filter_node({IP, Port}, Nodes) ->
    [X || {_NID, NIP, NPort}=X <- Nodes, NIP =/= IP orelse NPort =/= Port].

token_value(Peer, Token) ->
    X = term_to_binary(Peer),
    crypto:hmac(sha256, Token, X, 8).

is_valid_token(TokenValue, Peer, Tokens) ->
    ValidValues = [token_value(Peer, Token) || Token <- queue:to_list(Tokens)],
    lists:member(TokenValue, ValidValues).

%% Error common inhabits the common errors in the network stack.
%% This is used to validate that the error we got, was one of the well-known errors
%% In other words, the assumption is that ALL errors produced by this subsystem
%% falls into this group.
error_common(enobufs) -> fail;
error_common(ehostunreach) -> fail;
error_common(econnrefused) -> fail;
error_common(ehostdown) -> fail;
error_common(enetdown) -> fail.


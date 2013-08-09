-module(etorrent_mdns_state).
-behaviour(gen_server).


-export([start_link/1,
         get_peers/1]).
-export([remote_peer_up/3,
         remote_peer_down/3,
         remote_torrent_up/3,
         remote_torrent_down/3,
         remote_announce_request/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type peerid() :: etorrent_types:peerid().
-type infohash() :: etorrent_types:infohash().

-record(mdns_peer, {
    id :: peerid(),
    ip :: inet:ip_address(),
    bt_port :: inet:port_number()
}).
-record(mdns_torrent, {
    id :: infohash() | '_',
    peer_id :: peerid()
}).

-record(state, {
    %% HEX-string, 40 characters.
    my_peer_id :: string(),
    torrent_table :: ets:tab(),
    peer_table :: ets:tab()
}).

srv_name() ->
    etorrent_mdns_state_server.

start_link(MyPeerIdBin) ->
    gen_server:start_link({local, srv_name()},
                          ?MODULE,
                          [MyPeerIdBin], []).

get_peers(InfoHashBin) ->
    gen_server:call(srv_name(), {get_peers, InfoHashBin}).


%% @private
cast(Msg) ->
    gen_server:cast(srv_name(), Msg).

remote_peer_up(PeerId, IP, BTPort) ->
    cast({remote_peer_up, to_bin(PeerId), IP, BTPort}).

remote_peer_down(PeerId, IP, BTPort) ->
    cast({remote_peer_down, to_bin(PeerId), IP, BTPort}).

remote_torrent_up(PeerId, IP, IH) ->
    cast({remote_torrent_up, to_bin(PeerId), IP, to_bin(IH)}).

remote_torrent_down(PeerId, IP, IH) ->
    cast({remote_torrent_down, to_bin(PeerId), IP, to_bin(IH)}).

remote_announce_request(IP) ->
    cast({remote_announce_request, IP}).

%% ------------------------------------------------------------------

%% @private
init([MyPeerIdBin]) ->
    %% <<_:160>>
    PT = ets:new(etorrent_mdns_peer, [named_table, {keypos, #mdns_peer.id}]),
    TT = ets:new(etorrent_mdns_torrent, [named_table, bag, {keypos, #mdns_torrent.id}]),
    MyPeerIdStr = literal_hex_peer_id(MyPeerIdBin),
    mdns_event:add_sup_handler(etorrent_mdns_h, [MyPeerIdStr]),
    State = #state{my_peer_id = MyPeerIdStr,
                   peer_table = PT,
                   torrent_table = TT},
    {ok, State}.

%% @private
handle_call({get_peers, IH}, _From,
            State=#state{peer_table=PT, torrent_table=TT}) ->
    lager:debug("Get peers for ~p.", [IH]),
    Peers = [{IP, Port}
     || #mdns_torrent{peer_id=PeerId} <- ets:lookup(TT, IH),
        #mdns_peer{ip=IP, bt_port=Port} <- ets:lookup(PT, PeerId)],
    {reply, Peers, State}.

%% @private
handle_cast({remote_peer_up, PeerId, IP, BTPort},
            State=#state{peer_table=PT}) ->
    lager:debug("Add peer ~p from ~p:~p.", [PeerId, IP, BTPort]),
    ets:insert(PT, #mdns_peer{id=PeerId, ip=IP, bt_port=BTPort}),
    {noreply, State};
handle_cast({remote_peer_down, PeerId, IP, BTPort},
            State=#state{peer_table=PT, torrent_table=TT}) ->
    lager:debug("Remote peer ~p from ~p:~p.", [PeerId, IP, BTPort]),
    ets:match_delete(PT, #mdns_peer{id=PeerId, ip=IP, bt_port=BTPort, _='_'}),
    ets:delete(TT, #mdns_torrent{peer_id=PeerId, _='_'}),
    {noreply, State};
handle_cast({remote_torrent_up, PeerId, _IP, IH},
            State=#state{torrent_table=TT}) ->
    lager:debug("Add torrent ~p from ~p.", [IH, PeerId]),
    ets:insert(TT, #mdns_torrent{id=IH, peer_id=PeerId}),
    {noreply, State};
handle_cast({remote_torrent_down, PeerId, _IP, IH},
            State=#state{torrent_table=TT}) ->
    lager:debug("Remove torrent ~p from ~p.", [IH, PeerId]),
    ets:delete(TT, #mdns_torrent{id=IH, peer_id=PeerId, _='_'}),
    {noreply, State};
handle_cast({remote_announce_request, _IP}, State) ->
    {noreply, State}.

%% @private
handle_info(_, State) ->
    {noreply, State}.

%% @private
terminate(_, State) ->
    {ok, State}.


%% @private
code_change(_, State, _) ->
    {ok, State}.

literal_hex_peer_id(<<PeerIdInt:160>>) ->
    binary_to_list(list_to_binary(integer_peer_id_to_literal(PeerIdInt))).

integer_peer_id_to_literal(PeerIdInt) when is_integer(PeerIdInt) ->
    io_lib:format("~40.16.0B", [PeerIdInt]).

to_bin(<<_:160>> = Bin) -> Bin;
to_bin([_|_] = List) when length(List) =:= 40 ->
    Int = list_to_integer(List, 16),
    <<Int:160>>.

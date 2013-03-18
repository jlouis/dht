-module(etorrent_magnet_peer_sup).
-behaviour(supervisor).

%% API
-export([start_link/8]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type capabilities() :: etorrent_types:capabilities().

%% ====================================================================

%% @doc Start the peer
%% <p>A peer is fed with quite a lot of data. It gets tracker url, our
%% local `PeerId', it gets the `InfoHash', the Torrents `TorrentId', the pair
%% `{IP, Port}' of the remote peer, what `Capabilities' the peer supports
%% and a `Socket' for communication.</p>
%% <p>From that a supervisor for the peer and accompanying processes
%% are spawned.</p>
%% @end
-spec start_link(string(), binary(), binary(),
                 binary(), integer(), {ipaddr(), portnum()},
                 [capabilities()], port()) ->
            {ok, pid()} | ignore | {error, term()}.
start_link(TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
           TorrentId, {IP, Port}, Capabilities, Socket) ->
    Params = [TrackerUrl, LocalPeerId, RemotePeerId, InfoHash, TorrentId,
              {IP, Port}, Capabilities, Socket],
    supervisor:start_link(?MODULE, Params).

%% ====================================================================

%% @private
init([TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
      TorrentId, {IP, Port}, Caps, Socket]) ->
    Control = {control, {etorrent_magnet_peer_ctl, start_link,
                          [TrackerUrl, LocalPeerId, RemotePeerId,
                           InfoHash, TorrentId, {IP, Port}, Caps, Socket]},
                permanent, 5000, worker, [etorrent_magnet_peer_ctl]},
    Receiver = {receiver, {etorrent_peer_recv, start_link,
                          [TorrentId, Socket]},
                permanent, 5000, worker, [etorrent_peer_recv]},
    Sender   = {sender,   {etorrent_peer_send, start_link,
                          [Socket, TorrentId, false]},
                permanent, 5000, worker, [etorrent_peer_send]},
    {ok, {{one_for_all, 0, 1}, [Control, Sender, Receiver]}}.

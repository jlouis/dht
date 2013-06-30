%% Metadata downloader.
%% http://wiki.vuze.com/w/Magnet_link
-module(etorrent_magnet).
%% Public API
-export([download/1,
         download/2]).

%% Private callbacks
-export([handle_completion/5]).

%% Used for testing
%-export([download_meta_info/2,
%         build_torrent/2,
%         write_torrent/2,
%         parse_url/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_RECEIVE_TIMEOUT, 5000).
-define(DEFAULT_AWAIT_TIMEOUT, 25000).

-define(URL_PARSER, mochiweb_util).

%% The extension message IDs are the IDs used to send the extension messages
%% to the peer sending this handshake.
%% i.e. The IDs are local to this particular peer.


%% It is metadata extension id for this node.
%% It will be passed during handshake.
%% It can be any from 1..255.
-define(UT_METADATA_EXT_ID, 15).


%% @doc Parse a magnet link into a tuple "{Infohash, Description, Trackers}".
-spec parse_url(Url) -> {XT, DN, [TR]} when
    Url :: string(),
    XT :: non_neg_integer(),
    DN :: string() | undefined,
    TR :: string().
parse_url(Url) ->
    {Scheme, _Netloc, _Path, Query, _Fragment} = ?URL_PARSER:urlsplit(Url),
    case Scheme of
        "magnet" ->
            %% Get a parameter proplist. Keys and values are strings.
            Params = ?URL_PARSER:parse_qs(Query),
            analyse_params(Params, undefined, undefined, []);
        _ ->
            error({unknown_scheme, Scheme, Url})
    end.

analyse_params([{K,V}|Params], XT, DN, TRS) ->
    case K of
        "xt" ->
            analyse_params(Params, V, DN, TRS);
        "dn" ->
            analyse_params(Params, XT, V, TRS);
        "tr" ->
            analyse_params(Params, XT, DN, [V|TRS]);
        _ ->
            lager:error("Unknown magnet link parameter ~p.", [K])
    end;
analyse_params([], undefined, _DN, _TRS) ->
    error(undefined_xt);
analyse_params([], XT, DN, TRS) ->
    {xt_to_integer(list_to_binary(XT)), DN, lists:reverse(TRS)}.

xt_to_integer(<<"urn:btih:", Base16:40/binary>>) ->
    list_to_integer(binary_to_list(Base16), 16);
xt_to_integer(<<"urn:btih:", Base32:32/binary>>) ->
    etorrent_utils:base32_binary_to_integer(Base32).


-type peerid() :: <<_:160>>.
-type infohash_bin() :: <<_:160>>.
-type infohash_int() :: integer().
-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type bcode() :: etorrent_types:bcode().

download(Address) ->
    download(Address, []).

download({address, Address}, Options) ->
    case iolist_to_binary(Address) of
        <<"magnet:", _/binary>> = Bin ->
            download({magnet_link, binary_to_list(Bin)}, Options);
        <<Base16:40/binary>> ->
            IH = list_to_integer(binary_to_list(Base16), 16),
            download({infohash, IH}, Options);
        <<Base32:32/binary>> ->
            IH = etorrent_utils:base32_binary_to_integer(Base32),
            download({infohash, IH}, Options)
    end;
download({infohash, IntIH}, Options) when is_integer(IntIH) ->
    LocalPeerId = etorrent_ctl:local_peer_id(),
    BinIH = <<IntIH:160>>,
    UrlTiers = [],
    TorrentId = etorrent_counters:next(torrent),
    etorrent_torrent_pool:
    start_magnet_child(BinIH, LocalPeerId, TorrentId, UrlTiers, Options),
    {ok, TorrentId};
download({magnet_link, Link}, Options) when is_list(Link) ->
    LocalPeerId = etorrent_ctl:local_peer_id(),
    {IntIH, _, Trackers} = parse_url(Link),
    BinIH = <<IntIH:160>>,
    UrlTiers = [Trackers],
    TorrentId = etorrent_counters:next(torrent),
    etorrent_torrent_pool:
    start_magnet_child(BinIH, LocalPeerId, TorrentId, UrlTiers, Options),
    {ok, TorrentId}.

%% ------------------------------------------------------------------

handle_completion(RequiredIH, TorrentID, Info, UrlTiers, Options) ->
    {ok, DecodedInfo} = etorrent_bcoding:decode(Info),
    {ok, Torrent} = build_torrent(DecodedInfo, UrlTiers),
    {ok, FileName} = write_torrent(Torrent),
    case etorrent_ctl:start(FileName, Options) of
        {ok, Tid} ->
            lager:info("Changed the torrent id ~p => ~p.", [TorrentID, Tid]);
        {error, Reason} ->
            lager:error("Cannot start ~p, reason is ~p.", [RequiredIH, Reason])
    end.


-spec write_torrent(Torrent::bcode()) -> {ok, Out} | {error, term()} when
    Out :: file:filename().
write_torrent(Torrent) ->
    Name = filename:basename(etorrent_metainfo:get_name(Torrent)),
    Out = filename:join(etorrent_config:work_dir(), Name) ++ ".torrent",
    write_torrent(Out, Torrent).

%% @doc Write a value, returned from {@link download_meta_info/2} into a file.
-spec write_torrent(Out, Torrent::bcode()) -> {ok, Out} | {error, term()} when
    Out :: file:filename().
write_torrent(Out, Torrent) ->
    Encoded = etorrent_bcoding:encode(Torrent),
    case file:write_file(Out, Encoded) of
        ok -> {ok, Out};
        {error, Reason} -> {error, Reason}
    end.


-spec build_torrent(Info::bcode(), Trackers::[string()]) -> 
    {ok, Torrent::bcode()}.
build_torrent(InfoDecoded, Trackers) ->
    Torrent = add_trackers(Trackers) ++ [{<<"info">>, InfoDecoded}],
    {ok, Torrent}.


add_trackers([[T]]) ->
    [{<<"announce">>, iolist_to_binary(T)}];
add_trackers([[T|_]|_]=Teers) ->
    Teers1 = [[iolist_to_binary(Tracker) || Tracker <- Teer] || Teer <- Teers],
    [{<<"announce">>, iolist_to_binary(T)}, {<<"announce-list">>, Teers1}];
add_trackers([]) -> [].


-ifdef(TEST).

colton_url() ->
    "magnet:?xt=urn:btih:b48ed25b01668963e1f0ff782be383c5e7060eb4&"
    "dn=Jonathan+Coulton+-+Discography&"
    "tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.publicbt.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.istole.it%3A6969&"
    "tr=udp%3A%2F%2Ftracker.ccc.de%3A80".

parse_url_test_() ->
    [?_assertEqual({398417223648295740807581630131068684170926268560, undefined, []},
                   parse_url("magnet:?xt=urn:btih:IXE2K3JMCPUZWTW3YQZZOIB5XD6KZIEQ"))
    ,?_assertEqual({1030803369114085151184244669493103882218552823476,
                                   "Jonathan Coulton - Discography",
                                   ["udp://tracker.publicbt.com:80",
                                    "udp://tracker.openbittorrent.com:80",
                                    "udp://tracker.istole.it:6969",
                                    "udp://tracker.ccc.de:80"]},
                   parse_url(colton_url()))
    ].
-endif.

-module(etorrent_rlimit).
%% This module wraps the rlimit application and exports functions that
%% are expected to be called from etorrent_peer_send and etorrent_peer_recv.
%%
%% etorrent_peer_send is expected to aquire a slot after a message is sent.
%% etorrent_peer_recv is expected to aquire a slot after receiving a message.
-export([init/0,
         send/1,
         recv/1,
         send_rate/0,
         recv_rate/0,
         max_send_rate/0,
         max_recv_rate/0,
         max_send_rate/1,
         max_recv_rate/1]).

%% flow name definitions
-define(DOWNLOAD, etorrent_download_rlimit).
-define(UPLOAD, etorrent_upload_rlimit).


-spec send_rate() -> non_neg_integer().
send_rate() ->
    round(rlimit:prev_allowed(?UPLOAD)).


-spec recv_rate() -> non_neg_integer().
recv_rate() ->
    round(rlimit:prev_allowed(?DOWNLOAD)).


-spec max_recv_rate() -> non_neg_integer().
max_recv_rate() ->
    round(rlimit:get_limit(?DOWNLOAD)).

-spec max_recv_rate(non_neg_integer()) -> ok.
max_recv_rate(Value) ->
    rlimit:set_limit(?DOWNLOAD, Value).


-spec max_send_rate() -> non_neg_integer().
max_send_rate() ->
    round(rlimit:get_limit(?UPLOAD)).


-spec max_send_rate(non_neg_integer()) -> ok.
max_send_rate(Value) ->
    rlimit:set_limit(?UPLOAD, Value).


%% @doc Initialize the download and upload flows.
%% @end
-spec init() -> ok.
init() ->
    DLRate = etorrent_config:max_download_rate(),
    ULRate = etorrent_config:max_upload_rate(),
    ok = rlimit:new(?DOWNLOAD, to_byte_rate(DLRate), 1000),
    ok = rlimit:new(?UPLOAD, to_byte_rate(ULRate), 1000).

%% @doc Aquire a send slot.
%% A continue message will be sent to the caller once a slot has been aquired.
%% @end
-spec send(non_neg_integer()) -> pid().
send(Bytes) ->
    rlimit:atake(Bytes, {rlimit, continue}, ?UPLOAD).


%% @doc Aquire a receive slot.
%% A continue message will be sent to the caller once a slot has been aquired.
%% @end
-spec recv(non_neg_integer()) -> pid().
recv(Bytes) ->
    rlimit:atake(Bytes, {rlimit, continue}, ?DOWNLOAD).

%% @private Convert KB/s to B/s
to_byte_rate(infinity) ->
    infinity;
to_byte_rate(KB) ->
    1024 * KB.

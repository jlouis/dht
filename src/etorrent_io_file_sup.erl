%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc Maintain a pool of io_file processes
%% <p>This very simple supervisor keeps track of a set of file
%% processes for the I/O subsystem.</p>
%% @end
-module(etorrent_io_file_sup).
-behaviour(supervisor).

%% Use a separate supervisor for files. This ensures that
%% the directory server can assume that all files will be
%% closed if it crashes.

-export([start_link/3]).
-export([init/1]).

-type file_path() :: etorrent_types:file_path().
-type torrent_id() :: etorrent_types:torrent_id().


%% @doc Start the file pool supervisor
%% @end
-spec start_link(torrent_id(), file_path(), list(file_path())) -> {'ok', pid()}.
start_link(TorrentID, TorrentFile, Files) ->
    supervisor:start_link(?MODULE, [TorrentID, TorrentFile, Files]).

%% @private
init([TorrentID, Workdir, Files]) ->
    lager:debug("Init IO file supervisor for ~p.", [TorrentID]),
    FileSpecs  = file_server_specs(TorrentID, Workdir, Files, 1),
    lager:debug("Completing initialization of IO file supervisor for ~p.", [TorrentID]),
    lager:debug("Starting ~p IO file workers for ~p.", [length(FileSpecs), TorrentID]),
    {ok, {{one_for_all, 1, 60}, FileSpecs}}.

file_server_specs(TorrentID, Workdir, [Path|Paths], N) ->
    [file_server_spec(TorrentID, Workdir, Path, N)
    |file_server_specs(TorrentID, Workdir, Paths, N+1)];
file_server_specs(_TorrentID, _Workdir, [], _N) ->
    [].

file_server_spec(TorrentID, Workdir, Path, FileID) ->
    Fullpath = filename:join(Workdir, Path),
    %% FileID in the beginning of the worker key is an optimization.
    %% Key `{TorrentID, Path}' will work very slow, if there are few 
    %% thousand workers.
    %% The reason is that supervisor will check specs for duplicates.
    {{FileID, TorrentID, Path},
        {etorrent_io_file, start_link, [TorrentID, Path, Fullpath]},
        permanent, 2000, worker, [etorrent_io_file]}.

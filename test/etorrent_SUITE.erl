-module(etorrent_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([seed_leech/0, seed_leech/1,
	 seed_transmission/0, seed_transmission/1,
	 leech_transmission/0, leech_transmission/1,
     bep9/0, bep9/1]).

-define(TESTFILE30M, "test_file_30M.random").
-define(ET_WORK_DIR, "work-et").
-define(TR_WORK_DIR, "work-tr").

suite() ->
    [{timetrap, {minutes, 3}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(main_group, Config) ->
    init_locations(Config);
init_per_group(_Group, Config) ->
    Config.

end_per_group(main_group, Config) ->
    end_locations(Config);
end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    %% We should really use priv_dir here, but as we are for-once creating
    %% files we will later rely on for fetching, this is ok I think.
    Directory = ?config(data_dir, Config),
    io:format("Data directory: ~s~n", [Directory]),
    TestFn = ?TESTFILE30M,
    Fn = filename:join([Directory, TestFn]),
    ensure_random_file(Fn),
    file:set_cwd(Directory),
    TorrentFn = ensure_torrent_file(TestFn),
    %% Literal infohash.
    {ok, TorrentIH} = etorrent_dotdir:info_hash(TorrentFn),
    io:format(user, "Infohash is ~p.~n", [TorrentIH]),
    Pid = start_opentracker(Directory),
    {ok, SeedNode} = test_server:start_node('seeder', slave, []),
    {ok, LeechNode} = test_server:start_node('leecher', slave, []),
    {ok, MiddlemanNode} = test_server:start_node('middleman', slave, []),
    rpc:call(SeedNode,  code, set_path, [code:get_path()]),
    rpc:call(LeechNode, code, set_path, [code:get_path()]),
    rpc:call(MiddlemanNode, code, set_path, [code:get_path()]),
    %% Start SASL before lager, because SASL will set its error_handler
    %% otherwise.
%   ok = rpc:call(SeedNode,  application, start, [sasl]),
%   ok = rpc:call(LeechNode, application, start, [sasl]),
    ok = rpc:call(SeedNode,  lager, start, []),
    ok = rpc:call(LeechNode, lager, start, []),
    ok = rpc:call(LeechNode, lager, set_loglevel, [lager_console_backend, debug]),
    ok = rpc:call(SeedNode,  lager, set_loglevel, [lager_console_backend, debug]),
    [{info_hash, TorrentIH},
     {tracker_port, Pid},
     {leech_node, LeechNode},
     {middleman_node, MiddlemanNode},
     {seed_node, SeedNode} | Config].

end_per_suite(Config) ->
    Pid = ?config(tracker_port, Config),
    LN = ?config(leech_node, Config),
    SN = ?config(seed_node, Config),
    stop_opentracker(Pid),
    test_server:stop_node(SN),
    test_server:stop_node(LN),
    ok.

end_locations(Config) ->
    io:format(user, "Cleaning private directory~n", []),
    DataDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),

    %% Remove locations
    %% 
%   ok = file:delete(filename:join([PrivDir, ?ET_WORK_DIR, ?TESTFILE30M])),
    ok = del_dir(filename:join([PrivDir, ?ET_WORK_DIR])),
    ok = file:delete(filename:join([PrivDir, ?TR_WORK_DIR, "settings.json"])),
    ok = del_dir(filename:join([PrivDir, ?TR_WORK_DIR])).


init_locations(Config) ->
    io:format(user, "Init locations~n", []),
    %% Setup locations that some of the test cases use
    DataDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    io:format(user, "PrivDir: ~p~n", [PrivDir]),

    %% Create locations
    file:make_dir(filename:join([PrivDir, ?ET_WORK_DIR])),
    file:make_dir(filename:join([PrivDir, ?TR_WORK_DIR])),

    %% Setup common locations
    SeedTorrent = filename:join([DataDir, ?TESTFILE30M ++ ".torrent"]),
    SeedFile    = filename:join([DataDir, ?TESTFILE30M]),
    SeedFastResume = filename:join([PrivDir, "seed_fast_resume"]),

    LeechFile    = filename:join([PrivDir, ?TESTFILE30M]),
    LeechFastResume = filename:join([PrivDir, "leech_fast_resume"]),

    InterFastResume = filename:join([PrivDir, "middleman_fast_resume"]),

    %% Setup Etorrent location
    EtorrentWorkDir          = filename:join([PrivDir, ?ET_WORK_DIR]),
    EtorrentLeechFile        = filename:join([PrivDir, ?ET_WORK_DIR, ?TESTFILE30M]),

    %% Setup Transmission locations
    TransMissionWorkDir      = filename:join([PrivDir, ?TR_WORK_DIR]),
    TransMissionFile     = filename:join([PrivDir, ?TR_WORK_DIR, ?TESTFILE30M]),
    {ok, _} = file:copy(filename:join([DataDir, "transmission", "settings.json"]),
			filename:join([TransMissionWorkDir, "settings.json"])),

    [{seed_torrent, SeedTorrent},
     {seed_file,    SeedFile},
     {seed_fast_resume, SeedFastResume},
     {leech_file,    LeechFile},
     {leech_fast_resume, LeechFastResume},
     {middleman_fast_resume, InterFastResume},
     {et_work_dir, EtorrentWorkDir},
     {et_leech_file, EtorrentLeechFile},
     {tr_work_dir, TransMissionWorkDir},
     {tr_file, TransMissionFile} | Config].

spawn_leecher(Config) ->
    CommonConf = ct:get_config(common_conf),
    LeechConfig = leech_configuration(Config,
				      CommonConf,
				      ?config(priv_dir, Config),
				      ?ET_WORK_DIR),
    ok = rpc:call(?config(leech_node, Config), etorrent, start_app, [LeechConfig]).

spawn_seeder(Config) ->
    CommonConf = ct:get_config(common_conf),
    SeedConfig = seed_configuration(Config,
				    CommonConf,
				    ?config(priv_dir, Config),
				    ?config(data_dir, Config)),
    ok = rpc:call(?config(seed_node, Config), etorrent, start_app, [SeedConfig]).

spawn_middleman(Config) ->
    CommonConf = ct:get_config(common_conf),
    InterConfig = middleman_configuration(Config,
				    CommonConf,
				    ?config(priv_dir, Config),
				    ?config(data_dir, Config)),
    ok = rpc:call(?config(middleman_node, Config), etorrent, start_app, [InterConfig]).

init_per_testcase(leech_transmission, Config) ->
    %% Feed transmission the file to work with
    {ok, _} = file:copy(?config(seed_file, Config),
			?config(tr_file, Config)),
    {Ref, Pid} = start_transmission(?config(data_dir, Config),
				    ?config(tr_work_dir, Config),
				    ?config(seed_torrent, Config)),
    ok = ct:sleep({seconds, 10}), %% Wait for transmission to start up
    spawn_leecher(Config),
    [{transmission_port, {Ref, Pid}} | Config];
init_per_testcase(seed_transmission, Config) ->
    {Ref, Pid} = start_transmission(?config(data_dir, Config),
				    ?config(tr_work_dir, Config),
				    ?config(seed_torrent, Config)),
    ok = ct:sleep({seconds, 8}), %% Wait for transmission to start up
    spawn_seeder(Config),
    [{transmission_port, {Ref, Pid}} | Config];
init_per_testcase(seed_leech, Config) ->
    spawn_seeder(Config),
    spawn_leecher(Config),
    Config;
init_per_testcase(bep9, Config) ->
    spawn_seeder(Config),
    spawn_leecher(Config),
    spawn_middleman(Config),
    Config;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(leech_transmission, Config) ->
    {_Ref, Pid} = ?config(transmission_port, Config),
    stop_transmission(Config, Pid),
    stop_leecher(Config),
    ?line ok = file:delete(?config(tr_file, Config)),
    ?line ok = file:delete(?config(et_leech_file, Config));
end_per_testcase(seed_transmission, Config) ->
    {_Ref, Pid} = ?config(transmission_port, Config),
    stop_transmission(Config, Pid),
    stop_seeder(Config),
    ?line ok = file:delete(?config(tr_file, Config));
end_per_testcase(seed_leech, Config) ->
    stop_seeder(Config),
    stop_leecher(Config),
    ?line ok = file:delete(?config(et_leech_file, Config));
end_per_testcase(bep9, Config) ->
    stop_seeder(Config),
    stop_leecher(Config),
    stop_middleman(Config),
%   ?line ok = file:delete(?config(et_leech_file, Config)),
    ok;
end_per_testcase(_Case, _Config) ->
    ok.

%% Configuration
%% ----------------------------------------------------------------------
seed_configuration(Config, CConf, PrivDir, DataDir) ->
    [{listen_ip, {127,0,0,2}},
     {port, 1741 },
     {udp_port, 1742 },
     {dht_port, 1743 },
     {dht_state, filename:join([PrivDir, "seeder_state.persistent"])},
     {dir, DataDir},
     {download_dir, DataDir},
     {logger_dir, PrivDir},
     {logger_fname, "seed_etorrent.log"},
     {fast_resume_file, ?config(seed_fast_resume, Config)} | CConf].

leech_configuration(Config, CConf, PrivDir) ->
    leech_configuration(CConf, PrivDir, ?ET_WORK_DIR).

leech_configuration(Config, CConf, PrivDir, DownloadSuffix) ->
    [{listen_ip, {127,0,0,3}},
     {port, 1751 },
     {udp_port, 1752 },
     {dht_port, 1753 },
     {dht_state, filename:join([PrivDir, "leecher_state.persistent"])},
     {dir, filename:join([PrivDir, DownloadSuffix])},
     {download_dir, filename:join([PrivDir, DownloadSuffix])},
     {logger_dir, PrivDir},
     {logger_fname, "leech_etorrent.log"},
     {fast_resume_file, ?config(leech_fast_resume, Config)} | CConf].

middleman_configuration(Config, CConf, PrivDir) ->
    middleman_configuration(CConf, PrivDir, ?ET_WORK_DIR).

middleman_configuration(Config, CConf, PrivDir, DownloadSuffix) ->
    [{listen_ip, {127,0,0,4}},
     {port, 1761 },
     {udp_port, 1762 },
     {dht_port, 1763 },
     {dht_state, filename:join([PrivDir, "middleman_state.persistent"])},
     {dir, filename:join([PrivDir, DownloadSuffix])},
     {download_dir, filename:join([PrivDir, DownloadSuffix])},
     {logger_dir, PrivDir},
     {logger_fname, "middleman_etorrent.log"},
     {fast_resume_file, ?config(middleman_fast_resume, Config)} | CConf].

%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{main_group, [shuffle], [seed_transmission, seed_leech, leech_transmission]}].
%   [{main_group, [], [bep9]}].

all() ->
    [{group, main_group}].

seed_transmission() ->
    [{require, common_conf, etorrent_common_config}].

%% Etorrent => Transmission
seed_transmission(Config) ->
    io:format(user, "~n======START SEED TRANSMISSION TEST CASE======~n", []),
    {Ref, Pid} = ?config(transmission_port, Config),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(seed_file, Config))
	=:= sha1_file(?config(tr_file, Config)).

%% Transmission => Etorrent
leech_transmission() ->
    [{require, common_conf, etorrent_common_config}].

leech_transmission(Config) ->
    io:format(user, "~n======START LEECH TRANSMISSION TEST CASE======~n", []),
    %% Set callback and wait for torrent completion.
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(?config(leech_node, Config),
		  etorrent, start,
		  [?config(seed_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(tr_file, Config))
	=:= sha1_file(?config(et_leech_file, Config)).

seed_leech() ->
    [{require, common_conf, etorrent_common_config}].

seed_leech(Config) ->
    io:format(user, "~n======START SEED AND LEECHING TEST CASE======~n", []),
    {Ref, Pid} = {make_ref(), self()},
    ok = rpc:call(?config(leech_node, Config),
		  etorrent, start,
		  [?config(seed_torrent, Config), {Ref, Pid}]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(et_leech_file, Config))
	=:= sha1_file(?config(seed_file, Config)).


bep9() ->
    [{require, common_conf, etorrent_common_config}].

bep9(Config) ->
    io:format(user, "~n======START SEED AND LEECHING BEP-9 TEST CASE======~n", []),
    IntegerIH = literal_infohash_to_integer(?config(info_hash, Config)),
%   {Ref, Pid} = {make_ref(), self()},
    %
    LeechNode     = ?config(leech_node, Config),
    SeedNode      = ?config(seed_node, Config),
    MiddlemanNode = ?config(middleman_node, Config),

    %% Connect DHT nodes
    SeedTcpPort   = rpc:call(SeedNode,  etorrent_config, dht_port, []),
    LeechTcpPort  = rpc:call(LeechNode, etorrent_config, dht_port, []),
    true = rpc:call(MiddlemanNode,
    	  etorrent_dht_state, safe_insert_node,
    	  [{127,0,0,1}, LeechTcpPort]),
    true = rpc:call(MiddlemanNode,
    	  etorrent_dht_state, safe_insert_node,
    	  [{127,0,0,1}, SeedTcpPort]),


    LeechPeerId = rpc:call(LeechNode, etorrent_ctl, local_peer_id, []),

    %% Connect to our one-node DHT network.
    %% etorrent_dht_state:safe_insert_node({127,0,0,1}, 6881).
    true = rpc:call(LeechNode,
    	  etorrent_dht_state, safe_insert_node,
    	  [{127,0,0,1}, SeedTcpPort]),
   
    %% Wait for announce.
    timer:sleep(2000),

    %% Example:
    %% etorrent_magnet:download_meta_info(<<"-ETd011-698280551289">>, 
    %%      135913333321098763031843201180023309283666486509),
    Res = rpc:call(LeechNode,
    	  etorrent_magnet, download_meta_info,
    	  [LeechPeerId, IntegerIH]),
    io:format(user, "Meta: ~p~n", [Res]),
    receive
	{Ref, done} -> ok
    after
	120*1000 -> exit(timeout_error)
    end,
    sha1_file(?config(et_leech_file, Config))
	=:= sha1_file(?config(seed_file, Config)).



%% Helpers
%% ----------------------------------------------------------------------
start_opentracker(Dir) ->
    ToSpawn = "run_opentracker.sh -i 127.0.0.1 -p 6969",
    Spawn = filename:join([Dir, ToSpawn]),
    Pid = spawn(fun() ->
			Port = open_port(
				 {spawn, Spawn}, [binary, stream, eof]),
			receive
			    close ->
				port_close(Port)
			end
		end),
    Pid.

quote(Str) ->
    lists:concat(["'", Str, "'"]).

start_transmission(DataDir, DownDir, Torrent) ->
    io:format(user, "Start transmission~n", []),
    ToSpawn = ["run_transmission-cli.sh ", quote(Torrent),
	       " -w ", quote(DownDir),
	       " -g ", quote(DownDir),
	       " -p 1780"],
    Spawn = filename:join([DataDir, lists:concat(ToSpawn)]),
    error_logger:info_report([{spawn, Spawn}]),
    Ref = make_ref(),
    Self = self(),
    Pid = spawn_link(fun() ->
			Port = open_port(
				 {spawn, Spawn},
				 [stream, binary, eof]),
            transmission_loop(Port, Ref, Self, <<>>, <<>>)
		     end),
    {Ref, Pid}.

stop_transmission(Config, Pid) when is_pid(Pid) ->
    io:format(user, "Stop transmission~n", []),
    Pid ! close,
    end_transmission_locations(Config),
    ok.

end_transmission_locations(Config) ->
    io:format(user, "Cleaning transmission directory.", []),
    PrivDir = ?config(priv_dir, Config),

    %% Transmission dir needs some help:
    ok = del_dir_r(filename:join([PrivDir, ?TR_WORK_DIR, "resume"])),
    ok = del_dir_r(filename:join([PrivDir, ?TR_WORK_DIR, "torrents"])),
    ok = del_dir_r(filename:join([PrivDir, ?TR_WORK_DIR, "blocklists"])),
    ok.


stop_leecher(Config) ->
    ok = rpc:call(?config(leech_node, Config), etorrent, stop_app, []),
    ok = file:delete(filename:join([?config(priv_dir, Config),
				    "leech_etorrent.log"])),
    ok = file:delete(?config(leech_fast_resume, Config)).

stop_seeder(Config) ->
    ok = rpc:call(?config(seed_node, Config), etorrent, stop_app, []),
    ok = file:delete(filename:join([?config(priv_dir, Config),
				    "seed_etorrent.log"])),
    ok = file:delete(?config(seed_fast_resume, Config)).

stop_middleman(Config) ->
    ok = rpc:call(?config(middleman_node, Config), etorrent, stop_app, []),
    ok = file:delete(filename:join([?config(priv_dir, Config),
				    "middleman_etorrent.log"])),
    ok = file:delete(?config(middleman_fast_resume, Config)).

transmission_complete_criterion() ->
%   "Seeding, uploading to".
    "Verifying local files (0.00%, 100.00% valid)".

transmission_loop(Port, Ref, ReturnPid, OldBin, OldLine) ->
    case binary:split(OldBin, [<<"\r">>, <<"\n">>]) of
	[OnePart] ->
	    receive
		{Port, {data, Data}} ->
		    transmission_loop(Port, Ref, ReturnPid, <<OnePart/binary,
							      Data/binary>>, OldLine);
		close ->
		    port_close(Port);
		M ->
		    error_logger:error_report([received_unknown_msg, M]),
		    transmission_loop(Port, Ref, ReturnPid, OnePart, OldLine)
	    end;
	[L, Rest] ->
        %% Is it a different line? than show it.
        [io:format(user, "TRANS: ~s.~n", [L]) || L =/= OldLine],
	    case string:str(binary_to_list(L), transmission_complete_criterion()) of
		0 -> ok;
		N when is_integer(N) ->
		    ReturnPid ! {Ref, done}
	    end,
	    transmission_loop(Port, Ref, ReturnPid, Rest, L)
    end.

stop_opentracker(Pid) ->
    Pid ! close.

ensure_torrent_file(Fn) ->
    TorrentFn = Fn ++ ".torrent",
    case filelib:is_regular(TorrentFn) of
	true ->
	    ok;
	false ->
	    etorrent_mktorrent:create(
	      Fn, "http://localhost:6969/announce", TorrentFn)
    end,
    TorrentFn.

ensure_random_file(Fn) ->
    case filelib:is_regular(Fn) of
	true ->
	    ok;
	false ->
	    create_torrent_file(Fn)
    end.

create_torrent_file(FName) ->
    random:seed({137, 314159265, 1337}),
    Bin = create_binary(30*1024*1024, <<>>),
    file:write_file(FName, Bin).

create_binary(0, Bin) -> Bin;
create_binary(N, Bin) ->
    Byte = random:uniform(256) - 1,
    create_binary(N-1, <<Bin/binary, Byte:8/integer>>).

sha1_file(F) ->
    Ctx = crypto:sha_init(),
    {ok, FD} = file:open(F, [read,binary,raw]),
    FinCtx = sha1_round(FD, file:read(FD, 1024*1024), Ctx),
    crypto:sha_final(FinCtx).

sha1_round(_FD, eof, Ctx) ->
    Ctx;
sha1_round(FD, {ok, Data}, Ctx) ->
    sha1_round(FD, file:read(FD, 1024*1024), crypto:sha_update(Ctx, Data)).



del_dir_r(DirName) ->
    {ok, SubFiles} = file:list_dir(DirName),
    [file:delete(X) || X <- SubFiles],
    del_dir(DirName).

del_dir(DirName) ->
    io:format(user, "Try to delete directory ~p.~n", [DirName]),
    case file:del_dir(DirName) of
        {error,eexist} ->
            io:format(user, "Directory is not empty. Content: ~n~p~n", 
                      [element(2, file:list_dir(DirName))]),
            ok;
        ok ->
            ok
    end.


literal_infohash_to_integer(X) ->
    list_to_integer(X, 16).

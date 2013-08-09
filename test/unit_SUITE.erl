%%%-------------------------------------------------------------------
-module(unit_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(endgame, etorrent_endgame).
-define(pending, etorrent_pending).
-define(chunkstate, etorrent_chunkstate).

%%--------------------------------------------------------------------
suite() ->
    [{timetrap,{seconds,30}}].

%%--------------------------------------------------------------------
init_per_suite(Config) ->
    ok = application:start(gproc),
    Config.

%%--------------------------------------------------------------------
end_per_suite(_Config) ->
    ok = application:stop(gproc),
    ok.

%%--------------------------------------------------------------------
init_per_group(endgame, Config) ->
    etorrent_utils:register(?MODULE),
    {ok, PPid} = ?pending:start_link(testid()),
    {ok, EPid} = ?endgame:start_link(testid()),
    ok = ?pending:receiver(EPid, PPid),
    ok = ?pending:register(PPid),
    [{ppid, PPid},
     {epid, EPid} | Config];
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
end_per_group(endgame, Config) ->
    etorrent_utils:unregister(?MODULE),
    ok = etorrent_utils:shutdown(?config(epid, Config)),
    ok = etorrent_utils:shutdown(?config(ppid, Config)),
    ok;
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
groups() -> [{magnet, [],
              [magnet_basic]},
             {endgame, [],
              [endgame_basic,
               endgame_active_one_fetched,
               endgame_active_one_stored,
               endgame_request_list]}].

%%--------------------------------------------------------------------
all() -> [{group, magnet}].

%%--------------------------------------------------------------------
    
testid() -> 0.
testpid() -> ?endgame:lookup_server(testid()).
testset() -> etorrent_pieceset:from_list([0], 8).
pending() -> ?pending:lookup_server(testid()).
mainpid() -> etorrent_utils:lookup(?MODULE).

endgame_basic() -> [].
endgame_basic(_Config) ->
    true = is_pid(?endgame:lookup_server(testid())),
    true = is_pid(?endgame:await_server(testid())),

    Pid1 = spawn_link(
             fun() ->
                     ?pending:register(pending()),
                     ?chunkstate:assigned(0, 0, 1, self(), testpid()),
                     mainpid() ! assigned,
                     etorrent_utils:expect(die)
             end),
    etorrent_utils:expect(assigned),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, testset(), testpid()),
    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    Pid1 ! die, etorrent_utils:wait(Pid1),

    Pid2 = spawn_link(
             fun() ->
                     ?pending:register(pending()),
                     ?chunkstate:assigned(0, 0, 1, self(), testpid()),
                     ?chunkstate:dropped(0, 0, 1, self(), testpid()),
                     mainpid() ! dropped,
                     etorrent_utils:expect(die)
             end),
    etorrent_utils:expect(dropped),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, testset(), testpid()),
    Pid2 ! die, etorrent_utils:wait(Pid2).

endgame_active_one_fetched() -> [].
endgame_active_one_fetched(_Config) ->
    %% Spawn a separate process to introduce the chunk into endgame
    Orig = spawn_link(
             fun() ->
                     ?pending:register(pending()),
                     ?chunkstate:assigned(0, 0, 1, self(), testpid()),
                     mainpid() ! assigned,
                     etorrent_utils:expect(die)
             end),
    etorrent_utils:expect(assigned),
    %% Spawn a process that aquires the chunk from endgame and marks it as fetched
    Fetch =
        fun() ->
                spawn_link(
                  fun() ->
                          ?pending:register(pending()),
                          {ok, [{0,0,1}]} = ?chunkstate:request(1, testset(), testpid()),
                          ?chunkstate:fetched(0, 0, 1, self(), testpid()),
                          mainpid() ! fetched,
                          etorrent_utils:expect(die)
                  end)
        end,
    Pid0 = Fetch(),
    Pid1 = Fetch(),
    etorrent_utils:expect(fetched),
    %% Expect endgame to not send out requests for the fetched chunk
    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    Pid0 ! die, etorrent_utils:wait(Pid0),
    etorrent_utils:ping([pending(), testpid()]),
    
    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    
    %% Expect endgame to not send out requests if two peers have fetched the request
    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    Pid1 ! die, etorrent_utils:wait(Pid1),
    etorrent_utils:ping([pending(), testpid()]),
    
    %% Expect endgame to send out request if the chunk is dropped before it's stored
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, testset(), testpid()),
    Orig ! die, etorrent_utils:wait(Orig),
    ok.

endgame_active_one_stored() -> [].
endgame_active_one_stored(Config) ->
    %% Spawn a separate process to introduce the chunk into endgame
    Orig = spawn_link(
             fun() ->
                     ?pending:register(pending()),
                     ?chunkstate:assigned(0, 0, 1, self(), testpid()),
                     mainpid() ! assigned,
                     etorrent_utils:expect(die)
             end),
    etorrent_utils:expect(assigned),
    
    %% Spawn a process that aquires the chunk from endgame and marks it as stored
    Pid = spawn_link(
            fun() ->
                    ?pending:register(pending()),
                    {ok, [{0,0,1}]} = ?chunkstate:request(1, testset(), testpid()),
                    ?chunkstate:fetched(0, 0, 1, self(), testpid()),
                    ?chunkstate:stored(0, 0, 1, self(), testpid()),
                    mainpid() ! stored,
                    etorrent_utils:expect(die)
            end),
    etorrent_utils:expect(stored),
    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    Pid ! die, etorrent_utils:wait(Pid),
    etorrent_utils:ping([pending(), testpid()]),

    {ok, assigned} = ?chunkstate:request(1, testset(), testpid()),
    Orig ! die, etorrent_utils:wait(Orig),
    ok.

endgame_request_list() -> [].
endgame_request_list(Config) ->
    Pid = spawn_link(
            fun() ->
                    ?pending:register(pending()),
                    ?chunkstate:assigned(0, 0, 1, self(), testpid()),
                    ?chunkstate:assigned(0, 1, 1, self(), testpid()),
                    ?chunkstate:fetched(0, 1, 1, self(), testpid()),
                    mainpid() ! assigned,
                    etorrent_utils:expect(die)
            end),
    etorrent_utils:expect(assigned),
    Requests = ?chunkstate:requests(testpid()),
    Pid ! die, etorrent_utils:wait(Pid),
    [{Pid,{0,0,1}}, {Pid,{0,1,1}}] = lists:sort(Requests),
    ok.

endgame_assigned_to_noone_test() -> [].
endgame_assigned_to_noone_test(Config) ->
    Assigned = gb_trees:empty(),
    NewAssigned = ?endgame:add_assigned({1,2,3}, Assigned),
    {1,2,3} = etorrent_utils:find(fun(_) -> true end,
                                  ?endgame:get_assigned(NewAssigned)),
    ok.

endgame_dropped_and_reassigned_test() -> [].
endgame_dropped_and_reassigned_test(Config) ->
    Pid = self(),
    Assigned1 = gb_trees:empty(),
    Assigned2 = ?endgame:add_assigned({1,2,3}, Pid, Assigned1),
    Assigned3 = ?endgame:del_assigned({1,2,3}, Pid, Assigned2),
    {1,2,3} = etorrent_utils:find(fun(_) -> true end,
                                  ?endgame:get_assigned(Assigned3)),
    ok.

%% --------------------------------------------------
colton_url() ->
    "magnet:?xt=urn:btih:b48ed25b01668963e1f0ff782be383c5e7060eb4&"
    "dn=Jonathan+Coulton+-+Discography&"
    "tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.publicbt.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.istole.it%3A6969&"
    "tr=udp%3A%2F%2Ftracker.ccc.de%3A80".

-define(magnet, etorrent_magnet).

magnet_basic() -> [].
magnet_basic(Config) ->
    {398417223648295740807581630131068684170926268560, undefined, []} =
        ?magnet:parse_url("magnet:?xt=urn:btih:IXE2K3JMCPUZWTW3YQZZOIB5XD6KZIEQ"),
    R = ?magnet:parse_url(colton_url()),
    ct:log(debug, 25, "~p", [R]),
    {1030803369114085151184244669493103882218552823476,
     "Jonathan Coulton - Discography",
     ["udp://tracker.openbittorrent.com:80",
      "udp://tracker.publicbt.com:80",
      "udp://tracker.istole.it:6969",
      "udp://tracker.ccc.de:80"]} = R,
    ok.

metadata_variant_basic() -> [].
metadata_variant_basic(Config) -> 
    PeerPid1 = list_to_pid("<0.666.0>"),
    V1 = etorrent_metadata_variant:new(),
    V2 = etorrent_metadata_variant:add_peer(PeerPid1, 1, V1),
    PieceNum0 = etorrent_metadata_variant:request_piece(PeerPid1, V2),
    0 = PieceNum0,
    {PeerProgress, GlobalProgress, V3} =
        etorrent_metadata_variant:save_piece(PeerPid1, PieceNum0, <<"data">>, V2),
    {downloaded, downloaded} = {PeerProgress, GlobalProgress},
    Data = etorrent_metadata_variant:extract_data(PeerPid1, V3),
    [<<"data">>] = Data,
    ok.

%% --------------------------------------------------
-define(monitors, etorrent_monitorset).

noop_proc() ->
    spawn_link(fun() -> receive shutdown -> ok end end).

was_monitored(Pid) ->
    receive
        {'DOWN', _, _, Pid, _} -> true
        after 100 -> false
    end.
    
monitor_increase_size_test() ->
    Set0 = ?monitors:new(),
    Set1 = ?monitors:insert(noop_proc(), 0, Set0),
    Set2 = ?monitors:insert(noop_proc(), 1, Set1),
    1 = ?monitors:size(Set1),
    2 = ?monitors:size(Set2),
    ok.

monitor_state_value_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    0 = ?monitors:fetch(Ref0, Set1),
    1 = ?monitors:fetch(Ref1, Set2),
    ok.

monitor_delete_value_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    Set3 = ?monitors:delete(Ref0, Set2),
    1 = ?monitors:fetch(Ref1, Set3),
    ok.

monitor_is_member_test() ->
    Set0 = ?monitors:new(),
    Ref0 = noop_proc(),
    Ref1 = noop_proc(),
    Set1 = ?monitors:insert(Ref0, 0, Set0),
    Set2 = ?monitors:insert(Ref1, 1, Set1),
    true = ?monitors:is_member(Ref0, Set2),
    true = ?monitors:is_member(Ref1, Set2),
    Set3 = ?monitors:delete(Ref1, Set2),
    true = ?monitors:is_member(Ref0, Set3),
    false= ?monitors:is_member(Ref1, Set3),
    ok.

monitor_one_test() ->
    Set0 = ?monitors:new(),
    Pid  = noop_proc(),
    Set1 = ?monitors:insert(Pid, 0, Set0),
    Pid ! shutdown,
    true = was_monitored(Pid),
    ok.

monitor_demonitor_one_test() ->
    Set0 = ?monitors:new(),
    Pid  = noop_proc(),
    Set1 = ?monitors:insert(Pid, 0, Set0),
    Set2 = ?monitors:delete(Pid, Set1),
    Pid ! shutdown,
    false = was_monitored(Pid),
    ok.

monitor_basic() -> [].
monitor_basic(Config) ->
    Set = ?monitors:new(),
    0 = ?monitors:size(Set),

    monitor_increase_size_test(),
    monitor_state_value_test(),
    monitor_delete_value_test(),
    monitor_is_member_test(),
    monitor_one_test(),
    monitor_demonitor_one_test(),
    ok.


-ifdef(TEST2).
piece_map_0_test() ->
    Size  = 2,
    Files = [{a, 4}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_1_test() ->
    Size  = 2,
    Files = [{a, 2}, {b, 2}],
    Map   = [{a, 0, 0, 2}, {b, 1, 0, 2}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

piece_map_2_test() ->
    Size  = 2,
    Files = [{a, 3}, {b, 1}],
    Map   = [{a, 0, 0, 2}, {a, 1, 2, 1}, {b, 1, 0, 1}],
    ?assertEqual(Map, make_piece_map_(Size, Files)).

chunk_pos_0_test() ->
    Offs = 1,
    Len  = 3,
    Map  = [{a, 0, 4}],
    Pos  = [{a, 1, 3}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)).

chunk_pos_1_test() ->
    Offs = 2,
    Len  = 4,
    Map  = [{a, 1, 8}],
    Pos  = [{a, 3, 4}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_pos_2_test() ->
    Offs = 3,
    Len  = 9,
    Map  = [{a, 2, 4}, {b, 0, 10}],
    Pos  = [{a, 5, 1}, {b, 0, 8}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 

chunk_post_3_test() ->
    Offs = 8,
    Len  = 5,
    Map  = [{a, 0, 3}, {b, 0, 13}],
    Pos  = [{b, 5, 5}],
    ?assertEqual(Pos, chunk_positions(Offs, Len, Map)). 
    
-endif.

-ifdef(TEST2).

piece_size_test_() ->
    %% 012|345|67-|
    [?_assertEqual(3, piece_size(0, 3, 8))
    ,?_assertEqual(3, piece_size(1, 3, 8))
    ,?_assertEqual(2, piece_size(2, 3, 8))
    %% 012|345|678|
    ,?_assertEqual(3, piece_size(2, 3, 9))
    ].

piece_count_test_() ->
    %% 012|345|6--|
    [?_assertEqual(3, piece_count(3, 7))
    %% 012|345|67-|
    ,?_assertEqual(3, piece_count(3, 8))
    %% 012|345|678|
    ,?_assertEqual(3, piece_count(3, 9))
    ,?_assertEqual(2, piece_count(25356))
    ].

-endif.

-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(timer, etorrent_timer).

assertMessage(Msg) ->
    receive
        Msg ->
            ?assert(true);
        Other ->
            ?assertEqual(Msg, Other)
        after 0 ->
            ?assertEqual(Msg, make_ref())
    end.

assertNoMessage() ->
    Ref = {no_message, make_ref()},
    self() ! Ref,
    receive
        Ref ->
            ?assert(true);
        Other ->
            ?assertEqual(Ref, Other)
    end.


%% @doc Run tests inside clean processes.
timer_test_() ->
    {spawn, [ ?_test(instant_send_case())
            , ?_test(instant_timeout_case())
            , ?_test(step_and_fire_case())
            , ?_test(cancel_and_step_case())
            , ?_test(step_and_cancel_case())
            , ?_test(duplicate_cancel_case())
            ]}.


instant_send_case() ->
    {ok, Pid} = ?timer:start_link(instant),
    Msg = make_ref(),
    Ref = ?timer:send_after(Pid, 1000, self(), Msg),
    assertMessage(Msg).


instant_timeout_case() ->
    {ok, Pid} = ?timer:start_link(instant),
    Msg = make_ref(),
    Ref = ?timer:start_timer(Pid, 1000, self(), Msg),
    assertMessage({timeout, Ref, Msg}).


step_and_fire_case() ->
    {ok, Pid} = ?timer:start_link(queue),
    ?timer:send_after(Pid, 1000, self(), a),
    Ref = ?timer:start_timer(Pid, 3000, self(), b),
    ?timer:send_after(Pid, 6000, self(), c),

    ?assertEqual(1000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage(a),

    ?assertEqual(2000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage({timeout, Ref, b}),

    ?assertEqual(3000, ?timer:step(Pid)),
    ?assertEqual(0, ?timer:step(Pid)),
    ?assertEqual(1, ?timer:fire(Pid)),
    assertMessage(c).


cancel_and_step_case() ->
    {ok, Pid} = ?timer:start_link(queue),
    Msg = make_ref(),
    Ref = ?timer:start_timer(Pid, 6000, self(), Msg),
    ?assertEqual(6000, ?timer:cancel(Pid, Ref)),
    ?assertEqual(0, ?timer:step(Pid)),
    assertNoMessage().


step_and_cancel_case() ->
    {ok, Pid} = ?timer:start_link(queue),
    Ref = ?timer:send_after(Pid, 500, self(), a),
    500 = ?timer:step(Pid),
    ?assertEqual(false, ?timer:cancel(Pid, Ref)),
    assertMessage(a).


duplicate_cancel_case() ->
    {ok, Pid} = ?timer:start_link(queue),
    Ref = ?timer:send_after(Pid, 500, self(), b),
    ?assertEqual(500, ?timer:cancel(Pid, Ref)),
    ?assertEqual(false, ?timer:cancel(Pid, Ref)).

-endif.

-ifdef(TEST2).
decode_test_() ->
    [?_assertEqual(decode(<<"d8:msg_typei0e5:piecei0ee">>),
                   {[{<<"msg_type">>, 0}, {<<"piece">>, 0}], <<"">>})].

-endif.

-ifdef(TEST2).

make_mask_test_() ->
    F = fun make_mask/4,
    % make_index(From, Size, PLen, TLen)
    %% |0123|4567|89--|
    %% |--xx|x---|----|
    [?_assertEqual(<<2#110:3>>        , F(2, 3,  4, 10))
    %% |012|345|678|9--|
    %% |--x|xx-|---|---|
    ,?_assertEqual(<<2#1100:4>>       , F(2, 3,  3, 10))
    %% |01|23|45|67|89|
    %% |--|xx|x-|--|--|
    ,?_assertEqual(<<2#01100:5>>      , F(2, 3,  2, 10))
    %% |0|1|2|3|4|5|6|7|8|9|
    %% |-|-|x|x|x|-|-|-|-|-|
    ,?_assertEqual(<<2#0011100000:10>>, F(2, 3,  1, 10))
    ,?_assertEqual(<<1:1>>            , F(2, 3, 10, 10))
    ,?_assertEqual(<<1:1, 0:1>>       , F(2, 3,  9, 10))
    %% |012|345|678|9A-|
    %% |xxx|xx-|---|---|
    ,?_assertEqual(<<2#1100:4>>       , F(0, 5,  3, 11))
    %% |012|345|678|9A-|
    %% |---|---|--x|---|
    ,?_assertEqual(<<2#0010:4>>       , F(8, 1,  3, 11))
    %% |012|345|678|9A-|
    %% |---|---|--x|x--|
    ,?_assertEqual(<<2#0011:4>>       , F(8, 2,  3, 11))
    ,?_assertEqual(<<-1:30>>, F(0, 31457279,  1048576, 31457280))
    ,?_assertEqual(<<-1:30>>, F(0, 31457280,  1048576, 31457280))
    ].

make_ungreedy_mask_test_() ->
    F = fun(From, Size, PLen, TLen) -> 
            make_mask(From, Size, PLen, TLen, false) end,
    % make_index(From, Size, PLen, TLen, false)
    %% |0123|4567|89A-|
    %% |--xx|x---|----|
    [?_assertEqual(<<2#000:3>>        , F(2, 3,  4, 11))
    %% |0123|4567|89A-|
    %% |--xx|xxxx|xx--|
    ,?_assertEqual(<<2#010:3>>        , F(2, 8,  4, 11))
    ].

add_directories_test_() ->
    Rec = add_directories(
        [#file_info{position=0, size=3, name="test/t1.txt"}
        ,#file_info{position=3, size=2, name="t2.txt"}
        ,#file_info{position=5, size=1, name="dir1/dir/x.x"}
        ,#file_info{position=6, size=2, name="dir1/dir/x.y"}
        ]),
    Names = el(Rec, #file_info.name),
    Sizes = el(Rec, #file_info.size),
    Positions = el(Rec, #file_info.position),
    Children  = el(Rec, #file_info.children),

    [Root|Elems] = Rec,
    MinNames  = el(simple_minimize_reclist(Elems), #file_info.name),
    
    %% {NumberOfFile, Name, Size, Position, ChildNumbers}
    List = [{0, "",             8, 0, [1, 3, 4]}
           ,{1, "test",         3, 0, [2]}
           ,{2, "test/t1.txt",  3, 0, []}
           ,{3, "t2.txt",       2, 3, []}
           ,{4, "dir1",         3, 5, [5]}
           ,{5, "dir1/dir",     3, 5, [6, 7]}
           ,{6, "dir1/dir/x.x", 1, 5, []}
           ,{7, "dir1/dir/x.y", 2, 6, []}
        ],
    ExpNames = el(List, 2),
    ExpSizes = el(List, 3),
    ExpPositions = el(List, 4),
    ExpChildren  = el(List, 5),
    
    [?_assertEqual(Names, ExpNames)
    ,?_assertEqual(Sizes, ExpSizes)
    ,?_assertEqual(Positions, ExpPositions)
    ,?_assertEqual(Children,  ExpChildren)
    ,?_assertEqual(MinNames, ["test", "t2.txt", "dir1"])
    ].


el(List, Pos) ->
    Children  = [element(Pos, X) || X <- List].



add_directories_test() ->
    [Root|_] = X=
    add_directories(
        [#file_info{position=0, size=3, name=
    "BBC.7.BigToe/Eoin Colfer. Artemis Fowl/artemis_04.mp3"}
        ,#file_info{position=3, size=2, name=
    "BBC.7.BigToe/Eoin Colfer. Artemis Fowl. The Arctic Incident/artemis2_03.mp3"}
        ]),
    ?assertMatch(#file_info{position=0, size=5}, Root).

% H = {file_info,undefined,
%           "BBC.7.BigToe/Eoin Colfer. Artemis Fowl. The Arctic Incident/artemis2_03.mp3",
%           undefined,file,[],0,5753284,1633920175,undefined}
% NextDir =  "BBC.7.BigToe/Eoin Colfer. Artemis Fowl/. The Arctic Incident


metadata_pieces_test_() ->
    crypto:start(),
    TorrentBin = crypto:rand_bytes(100000),
    Pieces = metadata_pieces(TorrentBin, 0, byte_size(TorrentBin)),
    [Last|InitR] = lists:reverse(Pieces),
    F = fun(Piece) -> byte_size(Piece) =:= ?METADATA_BLOCK_BYTE_SIZE end,
    [?_assertEqual(iolist_to_binary(Pieces), TorrentBin)
    ,?_assert(byte_size(Last) =< ?METADATA_BLOCK_BYTE_SIZE)
    ,?_assert(lists:all(F, InitR))
    ].

-endif.



-ifdef(TEST2).
check_last_piece_test_() ->
    %% Bytes:  |0123|4567|89AB|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxx-|
    [{"The last piece is not full.",
      ?_assertEqual(0, check_last_piece(3, 8, 4, 12))},
    %% Bytes:  |0123|4567|89AB|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxx-|
     {"The last piece has a standard size.",
      ?_assertEqual(0, check_last_piece(3, 9, 4, 12))},
    %% Bytes:  |0123|4567|89A-|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxx-|
    ?_assertEqual(1, check_last_piece(3, 8, 4, 11))
    ].

byte_to_piece_count_beetween_test_() ->
    [?_assertEqual(3, byte_to_piece_count_beetween(3, 8,  4,  20, true))
    ,?_assertEqual(0, byte_to_piece_count_beetween(0, 0,  10, 20, true))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 1,  10, 20, true))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 9,  10, 20, true))
    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 10, 10, 20, true))
    ,?_assertEqual(2, byte_to_piece_count_beetween(0, 11, 10, 20, true))
    ,?_assertEqual(2, byte_to_piece_count_beetween(1, 10, 10, 20, true))
    ,?_assertEqual(2, byte_to_piece_count_beetween(1, 11, 10, 20, true))

    ,?_assertEqual(1, byte_to_piece_count_beetween(0, 4,  4, 20, false))
    ,?_assertEqual(1, byte_to_piece_count_beetween(3, 8,  4, 20, false))
    ,?_assertEqual(1, byte_to_piece_count_beetween(2030, 1156,
                                                   524288, 600000, true))
    %% From: 2030 Size 1156 PLen 524288 Res -1
    %% test the heuristic.
    ,?_assertEqual(0, byte_to_piece_count_beetween(2030, 1156,
                                                   524288, 600000, false))
   
    %% Bytes:  |0123|4567|89A-|
    %% Pieces: |0   |1   |2   |
    %% Set:    |----|----|xxx-|
    ,?_assertEqual(1, byte_to_piece_count_beetween(8, 3, 4, 11, false))
    %% Bytes:  |0123|4567|89A-|
    %% Pieces: |0   |1   |2   |
    %% Set:    |----|----|xx--|
    ,?_assertEqual(0, byte_to_piece_count_beetween(8, 2, 4, 11, false))
    ].

-endif.


-ifdef(TEST2).
mask_to_size_test_() ->
    %% Ids:    |01234|
    %% Pieces: |----x|
    [?_assert(etorrent_pieceset:is_member(4, etorrent_pieceset:from_list([4], 5)))
    %% TLen: 18, PLen: 4, PCount: 5
    %% Bytes: 3*4 + 2
    %% Ids:    |01234|
    %% Pieces: |-xx--|
    %% Selected: 2*4
    ,?_assertEqual(8, mask_to_size(etorrent_pieceset:from_list([1,2], 5), 18, 4))
    %% Ids:    |01234|
    %% Pieces: |-xx-x|
    %% Selected: 2*4+2
    ,?_assertEqual(10, mask_to_size(etorrent_pieceset:from_list([1,2,4], 5), 18, 4))
    %% Ids:    |01234|
    %% Pieces: |----x|
    %% Selected: 2
    ,?_assertEqual(2, mask_to_size(etorrent_pieceset:from_list([4], 5), 18, 4))
    %% Ids:    |01234|
    %% Pieces: |x----|
    %% Selected: 4
    ,?_assertEqual(4, mask_to_size(etorrent_pieceset:from_list([0], 5), 18, 4))
    ,{"All pieces have the same size." %% 2 last pieces are selected.
     ,?_assertEqual(20, mask_to_size(etorrent_pieceset:from_list([8,9], 10), 100, 10))}
    ].

-endif.



-ifdef(TEST2).

unordered_mask_to_filelist_int_ungreedy_test_() ->
    FileName = filename:join(code:lib_dir(etorrent_core), 
                             "test/etorrent_eunit_SUITE_data/malena.torrent"),
    {ok, Torrent} = etorrent_bcoding:parse_file(FileName),
    Info = collect_static_file_info(Torrent),
    TorrentName = "Malena Ernmann 2009 La Voux Du Nord (2CD)",
    {Arr, _PLen, _TLen, _} = Info,
    List = lists:keysort(#file_info.size, array:sparse_to_list(Arr)),
    N2I     = file_name_to_ids(Arr),
    FileId  = fun(Name) -> dict:fetch(TorrentName ++ "/" ++ Name, N2I) end,
    Pieces  = fun(Id) -> #file_info{pieces=Ps} = array:get(Id, Arr), Ps end,
    GetName = fun(Id) -> #file_info{name=N} = array:get(Id, Arr), N end,
    CD1     = FileId("CD1 PopWorks"),
    Flac1   = FileId("CD1 PopWorks/Malena Ernman - La Voix Du Nord - PopWorks (CD 1).flac"),
    Log1    = FileId("CD1 PopWorks/Malena Ernman - La Voix Du Nord - PopWorks (CD 1).log"),
    Cue1    = FileId("CD1 PopWorks/Malena Ernman - La Voix Du Nord - PopWorks (CD 1).cue"),
    AU1     = FileId("CD1 PopWorks/Folder.auCDtect.txt"),

    CD2     = FileId("CD2 Arias"),
    AU2     = FileId("CD2 Arias/Folder.auCDtect.txt"),
    Flac2   = FileId("CD2 Arias/Malena Ernman - La Voix Du Nord - Arias (CD 2).flac"),
    Log2    = FileId("CD2 Arias/Malena Ernman - La Voix Du Nord - Arias (CD 2).log"),
    Cue2    = FileId("CD2 Arias/Malena Ernman - La Voix Du Nord - Arias (CD 2).cue"),
    AU2     = FileId("CD2 Arias/Folder.auCDtect.txt"),
    CD2Pieces   = Pieces(CD2),
    Flac2Pieces  = Pieces(Flac2),
    Log2Pieces   = Pieces(Log2),
    Cue2Pieces   = Pieces(Cue2),
    AU2Pieces    = Pieces(AU2),
    UnionCD2Pieces = etorrent_pieceset:union([Flac2Pieces, Log2Pieces,
                                              Cue2Pieces, AU2Pieces]),
    [{"Tiny files are not wanted, but will be downloaded too.",
      [?_assertEqual([Log1, Cue1, AU1, CD2],
                     mask_to_filelist_int(UnionCD2Pieces, Arr, false))
      ,?_assertEqual([Log1, Cue1, AU1, CD2],
                     mask_to_filelist_int(CD2Pieces, Arr, false))
      ,?_assertEqual([CD2],
                     minimize_filelist_priv([AU2, Flac2, Log2, Cue2], Arr))
      ,?_assertEqual([CD2],
                     minimize_filelist_priv([AU2, Flac2, Log2, Cue2, CD2], Arr))
      ,?_assertEqual([CD2],
                     minimize_filelist_priv([AU2, Cue2, CD2], Arr))
      ,?_assertEqual([0],
                     minimize_filelist_priv([AU2, Flac2, Log2, Cue2, 0], Arr))
      ]}
    ].

mask_to_filelist_int_test_() ->
    FileName = filename:join(code:lib_dir(etorrent_core), 
                             "test/etorrent_eunit_SUITE_data/coulton.torrent"),
    {ok, Torrent} = etorrent_bcoding:parse_file(FileName),
    Info = collect_static_file_info(Torrent),
    {Arr, _PLen, _TLen, _} = Info,
    N2I     = file_name_to_ids(Arr),
    FileId  = fun(Name) -> dict:fetch(Name, N2I) end,
    Pieces  = fun(Id) -> #file_info{pieces=Ps} = array:get(Id, Arr), Ps end,
    Week4   = FileId("Jonathan Coulton/Thing a Week 4"),
    BigBoom = FileId("Jonathan Coulton/Thing a Week 4/The Big Boom.mp3"),
    Ikea    = FileId("Jonathan Coulton/Smoking Monkey/04 Ikea.mp3"),
    Week4Pieces   = Pieces(Week4),
    BigBoomPieces = Pieces(BigBoom),
    IkeaPieces    = Pieces(Ikea),
    W4BBPieces    = etorrent_pieceset:union(Week4Pieces, BigBoomPieces),
    W4IkeaPieces  = etorrent_pieceset:union(Week4Pieces, IkeaPieces),
    [?_assertEqual([Week4], mask_to_filelist_int(Week4Pieces, Arr, true))
    ,?_assertEqual([Week4], mask_to_filelist_int(W4BBPieces, Arr, true))
    ,?_assertEqual([Ikea, Week4], mask_to_filelist_int(W4IkeaPieces, Arr, true))
    ].

mask_to_filelist_int_ungreedy_test_() ->
    FileName = filename:join(code:lib_dir(etorrent_core), 
               "test/etorrent_eunit_SUITE_data/joco2011-03-25.torrent"),
    {ok, Torrent} = etorrent_bcoding:parse_file(FileName),
    Info = collect_static_file_info(Torrent),
    {Arr, _PLen, _TLen, _} = Info,
    N2I     = file_name_to_ids(Arr),
    FileId  = fun(Name) -> dict:fetch(Name, N2I) end,
    Pieces  = fun(Id) -> #file_info{pieces=Ps, distinct_pieces=DPs} = 
                            array:get(Id, Arr), {Ps, DPs} end,
    T01     = FileId("joco2011-03-25/joco-2011-03-25t01.flac"),
    TXT     = FileId("joco2011-03-25/joco2011-03-25.txt"),
    FFP     = FileId("joco2011-03-25/joco2011-03-25.ffp"),

    {T01Pieces, T01DisPieces} = Pieces(T01),
    [{"Large file overlaps small files."
     ,?_assertEqual(lists:sort([FFP, TXT, T01]),
                    lists:sort(mask_to_filelist_int(T01Pieces, Arr, true)))}
    ,?_assert(T01Pieces =/= T01DisPieces)
    ,{"Match by distinct pieces."
     ,?_assertEqual([T01], mask_to_filelist_int(T01DisPieces, Arr, false))}
    ,{"Match by distinct pieces. Test for mask_to_filelist_rec_tiny_file."
    ,?_assertEqual(lists:sort([FFP, TXT, T01]),
                   lists:sort(mask_to_filelist_int(T01Pieces, Arr, false)))}
    ].

file_name_to_ids(Arr) ->
    F = fun(FileId, #file_info{name=Name}, Acc) -> [{Name, FileId}|Acc] end,
    dict:from_list(array:sparse_foldl(F, [], Arr)).

-endif.

-ifdef(TEST2).

byte_ranges_to_mask_test_() ->
    %% Bytes:  |0123|4567|89AB|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxx-|
    [?_assertEqual(<<2#010:3>>, byte_ranges_to_mask([{3,8}], 0, 4, 12,
                                                    false, <<>>)),
    %% Bytes:  |0123|4567|89AB|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxxx|
     ?_assertEqual(<<2#011:3>>, byte_ranges_to_mask([{3,9}], 0, 4, 12,
                                                    false, <<>>)),
    %% Bytes:  |0123|4567|89A-|
    %% Pieces: |0   |1   |2   |
    %% Set:    |---x|xxxx|xxx-|
     ?_assertEqual(<<2#011:3>>, byte_ranges_to_mask([{3,8}], 0, 4, 11,
                                                    false, <<>>))
    ].

-endif.

-ifdef(TEST2).

calc_piece_size_test_() ->
    %% PieceNum, PieceSize, TotalSize, PieceCount
    %% Bytes:  |0123|4567|89AB|
    %% Pieces: |0   |1   |2   |
    [?_assertEqual(4, calc_piece_size(0, 4, 12, 3)),
     ?_assertEqual(4, calc_piece_size(1, 4, 12, 3)),
     ?_assertEqual(4, calc_piece_size(2, 4, 12, 3)),
     ?_assertError(function_clause, calc_piece_size(3, 4, 12, 3)),
     ?_assertError(function_clause, calc_piece_size(-1, 4, 12, 3)),

    %% Bytes:  |0123|4567|89A-|
    %% Pieces: |0   |1   |2   |
     ?_assertEqual(4, calc_piece_size(0, 4, 11, 3)),
     ?_assertEqual(4, calc_piece_size(1, 4, 11, 3)),
     ?_assertEqual(3, calc_piece_size(2, 4, 11, 3))
    ].

-endif.

-ifdef(TEST2).
-define(set, ?MODULE).

new_test() ->
    Set = ?set:new(32, 2),
    ?assertEqual(32, ?set:size(Set)),
    ?assertEqual(?set:from_list(32, 2, [{0, 31}]), Set).

new_min_test() ->
    ?assertEqual({0, 2}, ?set:min(?set:new(32, 2))),
    ?assertEqual({0, 3}, ?set:min(?set:new(32, 3))).

min_smaller_test() ->
    Set = ?set:from_list(32, 4, [{0,1},{3, 31}]),
    ?assertEqual({0,2}, ?set:min(Set)).

min_empty_test() ->
    Set = ?set:from_list(32, 2, []),
    ?assertError(badarg, ?set:min(Set)).

min_zero_test() ->
    Set = ?set:from_list(2, 1, [{0,0}]),
    ?assertEqual({0,1}, ?set:min(Set)).

is_empty_test() ->
    Set = ?set:from_list(2, 1, []),
    ?assert(?set:is_empty(Set)).

not_is_empty_test() ->
    Set = ?set:from_list(2, 1, [{0,0}]),
    ?assertNot(?set:is_empty(Set)).

delete_invalid_length_test() ->
    ?assertError(badarg, ?set:delete(0, 0, ?set:new(32, 2))),
    ?assertError(badarg, ?set:delete(0, -1, ?set:new(32, 2))).

delete_invalid_offset_test() ->
    ?assertError(badarg, ?set:delete(-1, 1, ?set:new(32, 2))).

delete_empty_test() ->
    Set = ?set:from_list(32, 2, []),
    ?assertEqual(Set, ?set:delete(0, 1, Set)).

delete_head_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(0, 2, Set0),
    Set2 = ?set:delete(0, 3, Set1),
    ?assertEqual(?set:from_list(32, 2, [{2,31}]), Set1),
    ?assertEqual(?set:from_list(32, 2, [{3,31}]), Set2).

delete_head_size_test() ->
    Set = ?set:delete(0, 2, ?set:new(32, 2)),
    ?assertEqual(30, ?set:size(Set)).
    
delete_middle_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(2, 2, Set0),
    ?assertEqual(30, ?set:size(Set1)),
    ?assertEqual(?set:from_list(32, 2, [{0,1}, {4,31}]), Set1).

delete_end_test() ->
    Set0 = ?set:new(32, 2),
    Set1 = ?set:delete(30, 2, Set0),
    ?assertEqual(30, ?set:size(Set1)),
    ?assertEqual(?set:from_list(32, 2, [{0, 29}]), Set1).

delete_middle_range_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 1}, {4,5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 1}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(4, 2, Set0)),
    ?assertEqual(Set1, ?set:delete(3, 3, Set0)),
    ?assertEqual(Set1, ?set:delete(3, 4, Set0)).

delete_end_of_range_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 3}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(4, 2, Set0)),
    ?assertEqual(Set1, ?set:delete(4, 3, Set0)).

delete_start_of_range_test() ->
    Set0 = ?set:from_list(32, 2, [{10, 31}]),
    Set1 = ?set:from_list(32, 2, [{12, 31}]),
    ?assertEqual(Set1, ?set:delete(8, 4, Set0)).

delete_last_byte_test() ->
    Set0 = ?set:from_list(32, 2, [{0, 5}, {10, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 4}, {10, 31}]),
    ?assertEqual(Set1, ?set:delete(5, 1, Set0)).


insert_invalid_offset_test() ->
    ?assertError(badarg, ?set:insert(-1, 0, undefined)).

insert_invalid_length_test() ->
    ?assertError(badarg, ?set:insert(0, 0, undefined)),
    ?assertError(badarg, ?set:insert(0, -1, undefined)).

insert_empty_test() ->
    Set0 = ?set:from_list(32, 2, []),
    Set1 = ?set:new(32, 2),
    ?assertEqual(Set1, ?set:insert(0, 32, Set0)).

insert_head_test() ->
    Set0 = ?set:from_list(32, 2, [{2, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 31}]),
    ?assertEqual(Set1, ?set:insert(0, 2, Set0)).

insert_after_head_test() ->
    Set0 = ?set:from_list(2,1,[]),
    Set1 = ?set:insert(0, 1, Set0),
    Set2 = ?set:insert(1, 1, Set1),
    Exp  = ?set:from_list(2,1,[{0,1}]),
    ?assertEqual(Exp, Set2).

insert_with_middle_test() ->
    Set0 = ?set:from_list(32, 2, [{0,1}, {3,4}, {6,31}]),
    Set1 = ?set:from_list(32, 2, [{0,31}]),
    ?assertEqual(Set1, ?set:insert(1, 6, Set0)).

insert_past_end_test() ->
    Set0 = ?set:new(32, 2),
    ?assertError(badarg, ?set:insert(0, 33, Set0)).

in_test_() ->
    Set0 = ?set:from_list(32, 2, [{0, 31}]),
    Set1 = ?set:from_list(32, 2, [{0, 10}, {20, 31}]),
    [ ?_assertEqual(true,  ?set:in(5, 6, Set0))
    , ?_assertEqual(true,  ?set:in(0, 32, Set0))
    , ?_assertEqual(false, ?set:in(0, 35, Set0))
    , ?_assertEqual(false, ?set:in(0, 55, Set0))

    , ?_assertEqual(true,  ?set:in(3, 4, Set1))
    , ?_assertEqual(false, ?set:in(10, 4, Set1))
    , ?_assertEqual(false, ?set:in(10, 21, Set1))
    , ?_assertEqual(false, ?set:in(0, 31, Set1))
    ].

subtract_test_() ->
    T0 = ?set:from_list(32, 2, [{10, 20}]),
    T1 = ?set:from_list(32, 2, [{10, 10}, {15, 20}]),
    T2 = ?set:from_list(32, 2, [{15, 20}]),
    [ ?_assertEqual(subtract(11, 4, T0), {T1, [{11,4}]})
    , ?_assertEqual(subtract(5, 10, T0), {T2, [{10,5}]})
    , ?_assertEqual(subtract(21, 5, T0), {T0, []})
    ].

-endif.


-ifdef(TEST2).
-define(chunkstate, ?MODULE).

flush() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    [receive Msg -> Msg end || Msg <- Msgs].

pop() -> etorrent_utils:first().
make_pid() -> spawn(fun erlang:now/0).

chunkstate_test_() ->
    {foreach,local,
        fun() -> flush() end,
        fun(_) -> flush() end,
        [?_test(test_request()),
         ?_test(test_requests()),
         ?_test(test_assigned()),
         ?_test(test_assigned_list()),
         ?_test(test_dropped()),
         ?_test(test_dropped_list()),
         ?_test(test_dropped_all()),
         ?_test(test_fetched()),
         ?_test(test_stored()),
         ?_test(test_forward()),
         ?_test(test_contents())]}.

test_request() ->
    Peer = self(),
    Set  = make_ref(),
    Num  = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, {request, Num, Set, Peer}}) -> ok end)
    end),
    ?assertEqual(ok, ?chunkstate:request(Num, Set, Srv)).

test_requests() ->
    Ref = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, requests}) -> Ref end)
    end),
    ?assertEqual(Ref, ?chunkstate:requests(Srv)).

test_assigned() ->
    Pid = make_pid(),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()).

test_assigned_list() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:assigned(Chunks, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()).

test_dropped() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()).

test_dropped_list() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:dropped(Chunks, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {dropped, 4, 5, 6, Pid}}, pop()).

test_dropped_all() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(Pid, self()),
    ?assertEqual({chunk, {dropped, Pid}}, pop()).

test_fetched() ->
    Pid = make_pid(),
    ok = ?chunkstate:fetched(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {fetched, 1, 2, 3, Pid}}, pop()).

test_stored() ->
    Pid = make_pid(),
    ok = ?chunkstate:stored(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {stored, 1, 2, 3, Pid}}, pop()).

test_contents() ->
    ok = ?chunkstate:contents(1, 2, 3, <<1,2,3>>, self()),
    ?assertEqual({chunk, {contents, 1, 2, 3, <<1,2,3>>}}, pop()).

test_forward() ->
    Main = self(),
    Pid = make_pid(),
    {Slave, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        ?chunkstate:forward(Main),
        etorrent_utils:expect(die)
    end),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, Slave),
    ok = ?chunkstate:assigned(4, 5, 6, Pid, Slave),
    Slave ! go,
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()),
    Slave ! die,
    etorrent_utils:wait(Ref).

-endif.

-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(scarcity, ?MODULE).
-define(pieceset, etorrent_pieceset).
-define(timer, etorrent_timer).

pieces(Pieces) ->
    ?pieceset:from_list(Pieces, 8).

scarcity_server_test_() ->
    {setup,
        fun()  -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
        [?_test(register_case()),
         ?_test(server_registers_case()),
         ?_test(initial_ordering_case(test_data(2))),
         ?_test(empty_ordering_case(test_data(3))),
         ?_test(init_pieceset_case(test_data(4))),
         ?_test(one_available_case(test_data(5))),
         ?_test(decrement_on_exit_case(test_data(6))),
         ?_test(init_watch_case(test_data(7))),
         ?_test(add_peer_update_case(test_data(8))),
         ?_test(add_piece_update_case(test_data(9))),
         ?_test(aggregate_update_case(test_data(12))),
         ?_test(noaggregate_update_case(test_data(13))),
         ?_test(peer_exit_update_case(test_data(10))),
         ?_test(local_unwatch_case(test_data(11)))]}.

test_data(N) ->
    {ok, Time} = ?timer:start_link(queue),
    {ok, Pid} = ?scarcity:start_link(N, Time, 16),
    {N, Time, Pid}.

register_case() ->
    true = ?scarcity:register_server(0),
    ?assertEqual(self(), ?scarcity:lookup_server(0)),
    ?assertEqual(self(), ?scarcity:await_server(0)).

server_registers_case() ->
    {ok, Pid} = ?scarcity:start_link(1, 16),
    ?assertEqual(Pid, ?scarcity:lookup_server(1)).

initial_ordering_case({N, Time, Pid}) ->
    {ok, Order} = ?scarcity:get_order(N, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([0,1,2,3,4,5,6,7], Order).

empty_ordering_case({N, Time, Pid}) ->
    {ok, Order} = ?scarcity:get_order(3, pieces([])),
    ?assertEqual([], Order).

init_pieceset_case({N, Time, Pid}) ->
    ?assertEqual(ok, ?scarcity:add_peer(4, pieces([]))).

one_available_case({N, Time, Pid}) ->
    ok = ?scarcity:add_peer(N, pieces([])),
    ?assertEqual(ok, ?scarcity:add_piece(N, 0, pieces([0]))),
    Pieces  = pieces([0,1,2,3,4,5,6,7]),
    {ok, Order} = ?scarcity:get_order(N, Pieces),
    ?assertEqual([1,2,3,4,5,6,7,0], Order).

decrement_on_exit_case({N, Time, _}) ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?scarcity:add_peer(N, pieces([0])),
        ok = ?scarcity:add_piece(N, 2, pieces([0,2])),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    Pieces  = ?pieceset:from_list([0,1,2,3,4,5,6,7], 8),
    {ok, O1} = ?scarcity:get_order(N, pieces([0,1,2,3,4,5,6,7])),
    ?assertEqual([1,3,4,5,6,7,0,2], O1),
    Ref = monitor(process, Pid),
    Pid ! die,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, O2} = ?scarcity:get_order(N, Pieces),
    ?assertEqual([0,1,2,3,4,5,6,7], O2).

init_watch_case({N, Time, Pid}) ->
    {ok, Ref, Order} = ?scarcity:watch(N, seven, pieces([0,2,4,6])),
    ?assert(is_reference(Ref)),
    ?assertEqual([0,2,4,6], Order).

add_peer_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, eight, pieces([0,2,4,6])),
    ?assertEqual(1, ?timer:fire(Time)),
    ok = ?scarcity:add_peer(N, pieces([0,2])),
    receive
        {scarcity, Ref, Tag, Order} ->
            ?assertEqual(eight, Tag),
            ?assertEqual([4,6,0,2], Order);
        Other ->
            ?assertEqual(make_ref(), Other)
    end.

add_piece_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(9, nine, pieces([0,2,4,6])),
    ok = ?scarcity:add_peer(N, pieces([])),
    ok = ?scarcity:add_piece(N, 2, pieces([2])),
    ?assertEqual(5000, ?timer:step(Time)),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, nine, Order} ->
            ?assertEqual([0,4,6,2], Order)
    end.

aggregate_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, aggr, pieces([0,2,4,6])),
    %% Assert that peer is limited by default
    ?assertEqual(5000, ?timer:step(Time)),
    ok = ?scarcity:add_peer(N, pieces([2])),
    ok = ?scarcity:add_piece(N, 0, pieces([0,2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [4,6,0,2]} -> ok;
        Other -> ?assertEqual(make_ref(), Other)
        after 0 -> ?assert(false)
    end.

noaggregate_update_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, aggr, pieces([0,2,4,6])),
    %% Assert that peer is limited by default
    ?assertEqual(5000, ?timer:step(Time)),
    ok = ?scarcity:add_peer(N, pieces([2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [0,4,6,2]} -> ok;
        O1 -> ?assertEqual(make_ref(), O1)
        after 0 -> ?assert(false)
    end,
    ok = ?scarcity:add_piece(N, 0, pieces([0,2])),
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, aggr, [4,6,0,2]} -> ok;
        O2 -> ?assertEqual(make_ref(), O2)
        after 0 -> ?assert(false)
    end.



peer_exit_update_case({N, Time, _}) ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?scarcity:add_peer(N, pieces([0,1,2,3])),
        Main ! done,
        receive die -> ok end
    end),
    receive done -> ok end,
    {ok, Ref, _} = ?scarcity:watch(N, ten, pieces([0,2,4,6])),
    Pid ! die,
    ?assertEqual(1, ?timer:fire(Time)),
    receive
        {scarcity, Ref, ten, Order} ->
            ?assertEqual([0,2,4,6], Order)
    end.

local_unwatch_case({N, Time, Pid}) ->
    {ok, Ref, _} = ?scarcity:watch(N, eleven, pieces([0,2,4,6])),
    ?assertEqual(ok, ?scarcity:unwatch(N, Ref)),
    ok = ?scarcity:add_peer(N, pieces([0,1,2,3,4,5,6,7])),
    %% Assume that the message is sent before the add_peer call returns
    receive
        {scarcity, Ref, _, _} ->
            ?assert(false)
        after 0 ->
            ?assert(true)
    end.

-endif.

%%====================================================================
%% Tests
%%====================================================================
-ifdef(TEST2).

allowed_fast_1_test() ->
    N = 16#AA,
    InfoHash = list_to_binary(lists:duplicate(20, N)),
    {value, PieceSet} = allowed_fast(1313, {80,4,4,200}, 7, InfoHash),
    Pieces = lists:sort(sets:to_list(PieceSet)),
    ?assertEqual([287, 376, 431, 808, 1059, 1188, 1217], Pieces).

allowed_fast_2_test() ->
    N = 16#AA,
    InfoHash = list_to_binary(lists:duplicate(20, N)),
    {value, PieceSet} = allowed_fast(1313, {80,4,4,200}, 9, InfoHash),
    Pieces = lists:sort(sets:to_list(PieceSet)),
    ?assertEqual([287, 353, 376, 431, 508, 808, 1059, 1188, 1217], Pieces).

-endif.

-ifdef(TEST2).

fetch_id(Params) ->
    etorrent_bcoding:get_value(<<"id">>, Params).

query_ping_0_test() ->
   Enc = "d1:ad2:id20:abcdefghij0123456789e1:q4:ping1:t2:aa1:y1:qe",
   {ping, ID, Params} = decode_msg(Enc),
   ?assertEqual(<<"aa">>, ID),
   ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)).

query_find_node_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567896:"
        ++"target20:mnopqrstuvwxyz123456e1:q9:find_node1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {find_node, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, etorrent_bcoding:get_value(<<"target">>, Params)).

query_get_peers_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash"
        ++"20:mnopqrstuvwxyz123456e1:q9:get_peers1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {get_peers, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, etorrent_bcoding:get_value(<<"info_hash">>,Params)).

query_announce_peer_0_test() ->
    Enc = "d1:ad2:id20:abcdefghij01234567899:info_hash20:"
        ++"mnopqrstuvwxyz1234564:porti6881e5:token8:aoeusnthe1:"
        ++"q13:announce_peer1:t2:aa1:y1:qe",
    Res = decode_msg(Enc),
    {announce, ID, Params} = Res,
    ?assertEqual(<<"aa">>, ID),
    ?assertEqual(<<"abcdefghij0123456789">>, fetch_id(Params)),
    ?assertEqual(<<"mnopqrstuvwxyz123456">>, etorrent_bcoding:get_value(<<"info_hash">>,Params)),
    ?assertEqual(<<"aoeusnth">>, etorrent_bcoding:get_value(<<"token">>, Params)),
    ?assertEqual(6881, etorrent_bcoding:get_value(<<"port">>, Params)).

resp_ping_0_test() ->
    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, MsgID, Values} = Res,
    ID = decode_response(ping, Values),
    ?assertEqual(<<"aa">>, MsgID),
    ?assertEqual(etorrent_dht:integer_id(<<"mnopqrstuvwxyz123456">>), ID).

resp_find_node_0_test() ->
    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes0:e1:t2:aa1:y1:re",
    {response, _, Values} = decode_msg(Enc),
    {ID, Nodes} = decode_response(find_node, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"0123456789abcdefghij">>), ID),
    ?assertEqual([], Nodes).

resp_find_node_1_test() ->
    Enc = "d1:rd2:id20:0123456789abcdefghij5:nodes26:"
         ++ "0123456789abcdefghij" ++ [0,0,0,0,0,0] ++ "e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {_, Nodes} = decode_response(find_node, Values),
    ?assertEqual([{etorrent_dht:integer_id("0123456789abcdefghij"),
                   {0,0,0,0}, 0}], Nodes).

resp_get_peers_0_test() ->
    Enc = "d1:rd2:id20:abcdefghij01234567895:token8:aoeusnth6:values"
        ++ "l6:axje.u6:idhtnmee1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {ID, Token, Peers, _Nodes} = decode_response(get_peers, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"abcdefghij0123456789">>), ID),
    ?assertEqual(<<"aoeusnth">>, Token),
    ?assertEqual([{{97,120,106,101},11893}, {{105,100,104,116}, 28269}], Peers).

resp_get_peers_1_test() ->
    Enc = "d1:rd2:id20:abcdefghij01234567895:nodes26:"
        ++ "0123456789abcdefghijdef4565:token8:aoeusnthe"
        ++ "1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    {ID, Token, _Peers, Nodes} = decode_response(get_peers, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"abcdefghij0123456789">>), ID),
    ?assertEqual(<<"aoeusnth">>, Token),
    ?assertEqual([{etorrent_dht:integer_id(<<"0123456789abcdefghij">>),
                   {100,101,102,52},13622}], Nodes).

resp_announce_peer_0_test() ->
    Enc = "d1:rd2:id20:mnopqrstuvwxyz123456e1:t2:aa1:y1:re",
    Res = decode_msg(Enc),
    {response, _, Values} = Res,
    ID = decode_response(announce, Values),
    ?assertEqual(etorrent_dht:integer_id(<<"mnopqrstuvwxyz123456">>), ID).

valid_token_test() ->
    IP = {123,132,213,231},
    Port = 1779,
    TokenValues = init_tokens(10),
    Token = token_value(IP, Port, TokenValues),
    ?assertEqual(true, is_valid_token(Token, IP, Port, TokenValues)),
    ?assertEqual(false, is_valid_token(<<"not there at all!">>,
				       IP, Port, TokenValues)).

-ifdef(PROPER).

-type octet() :: byte().
%-type portnum() :: char().
-type dht_node() :: {{octet(), octet(), octet(), octet()}, portnum()}.
-type integer_id() :: non_neg_integer().
-type node_id() :: integer_id().
-type info_hash() :: integer_id().
%-type token() :: binary().
%-type transaction() ::binary().

-type ping_query() ::
    {ping, transaction(), {{'id', node_id()}}}.

-type find_node_query() ::
   {find_node, transaction(),
        {{'id', node_id()}, {'target', node_id()}}}.

-type get_peers_query() ::
   {get_peers, transaction(),
        {{'id', node_id()}, {'info_hash', info_hash()}}}.

-type announce_query() ::
   {announce, transaction(),
        {{'id', node_id()}, {'info_hash', info_hash()},
         {'token', token()}, {'port', portnum()}}}.

-type dht_query() ::
    ping_query() |
    find_node_query() |
    get_peers_query() |
    announce_query().




prop_inv_compact() ->
   ?FORALL(Input, list(dht_node()),
       begin
           Compact = peers_to_compact(Input),
           Output = compact_to_peers(iolist_to_binary(Compact)),
           Input =:= Output
       end).

prop_inv_compact_test() ->
    qc(prop_inv_compact()).

tobin(Atom) ->
    iolist_to_binary(atom_to_list(Atom)).

prop_query_inv() ->
   ?FORALL(TmpQ, dht_query(),
       begin
           {TmpMethod, TmpMsgId, TmpParams} = TmpQ,
           InQ  = {TmpMethod, <<0, TmpMsgId/binary>>,
                   lists:sort([{tobin(K),V} || {K, V} <- tuple_to_list(TmpParams)])},
           {Method, MsgId, Params} = InQ,
           EncQ = iolist_to_binary(encode_query(Method, MsgId, Params)),
           OutQ = decode_msg(EncQ),
           OutQ =:= InQ
       end).

prop_query_inv_test() ->
    qc(prop_query_inv()).

qc(Gen) ->
    Res = proper:quickcheck(Gen),
    case Res of
        true -> ok;
        Error -> io:format(user, "Proper error: ~p~n", [Error]), error(proper_error)
    end.

-endif. %% EQC
-endif.

-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").

hashes_to_binary_test_() ->
    Input = [<<1:160>>, <<2:160>>, <<3:160>>],
    Bin = hashes_to_binary(Input),
    [?_assertEqual(<<1:160>>, fetch_hash(0, Bin)),
     ?_assertEqual(<<2:160>>, fetch_hash(1, Bin)),
     ?_assertEqual(<<3:160>>, fetch_hash(2, Bin)),
     ?_assertEqual(3, num_hashes(Bin)),
     ?_assertError(badarg, fetch_hash(-1, Bin)),
     ?_assertError(badarg, fetch_hash(3, Bin))].


-endif.

-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(pending, ?MODULE).
-define(chunks, etorrent_chunkstate).
-define(expect, etorrent_utils:expect).
-define(wait, etorrent_utils:wait).
-define(ping, etorrent_utils:ping).
-define(first, etorrent_utils:first).


testid() -> 0.
testpid() -> ?pending:await_server(testid()).

setup_env() ->
    {ok, Pid} = ?pending:start_link(testid()),
    ok = ?pending:receiver(self(), Pid),
    put({pending, testid()}, Pid),
    Pid.

teardown_env(Pid) ->
    erase({pending, testid()}),
    ok = etorrent_utils:shutdown(Pid).

pending_test_() ->
    {setup, local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    {inorder,
    {foreach, local,
        fun setup_env/0,
        fun teardown_env/1,
    [?_test(test_registers()),
     ?_test(test_register_peer()),
     ?_test(test_register_twice()),
     ?_test(test_assigned_dropped()),
     ?_test(test_stored_not_dropped()),
     ?_test(test_dropped_not_dropped()),
     ?_test(test_drop_all_for_pid()),
     ?_test(test_change_receiver()),
     ?_test(test_drop_on_down()),
     ?_test(test_request_list())
    ]}}}.

test_registers() ->
    ?assert(is_pid(?pending:await_server(testid()))),
    ?assert(is_pid(?pending:lookup_server(testid()))).

test_register_peer() ->
    ?assertEqual(ok, ?pending:register(testpid())).

test_register_twice() ->
    ?assertEqual(ok, ?pending:register(testpid())),
    ?assertEqual(error, ?pending:register(testpid())).

test_assigned_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 0, 1, Pid}}),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_stored_not_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(store),
        ?chunks:stored(0, 0, 1, self(), testpid()),
        Main ! stored,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! store,
    ?expect(stored),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_dropped_not_dropped() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(drop),
        ?chunks:dropped(0, 0, 1, self(), testpid()),
        Main ! dropped,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! drop,
    ?expect(dropped),
    Pid ! die,
    ?wait(Pid),
    ?expect({chunk, {dropped, 0, 1, 1, Pid}}).

test_drop_all_for_pid() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(testpid()),
        Main ! assign,
        ?expect(drop),
        ?chunks:dropped(self(), testpid()),
        Main ! dropped,
        ?expect(die)
    end),
    ?expect(assign),
    ?chunks:assigned(0, 0, 1, Pid, testpid()),
    ?chunks:assigned(0, 1, 1, Pid, testpid()),
    Pid ! drop, ?expect(dropped),
    Pid ! die, ?wait(Pid),
    self() ! none,
    ?assertEqual(none, ?first()).

test_change_receiver() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ?pending:receiver(self(), testpid()),
        {peer, Peer} = ?first(),
        ?chunks:assigned(0, 0, 1, Peer, testpid()),
        ?chunks:assigned(0, 1, 1, Peer, testpid()),
        ?pending:receiver(Main, testpid()),
        ?expect(die)
    end),
    Peer = spawn_link(fun() ->
        ?pending:register(testpid()),
        Pid ! {peer, self()},
        ?expect(die)
    end),
    ?expect({chunk, {assigned, 0, 0, 1, Peer}}),
    ?expect({chunk, {assigned, 0, 1, 1, Peer}}),
    Pid ! die,  ?wait(Pid),
    Peer ! die, ?wait(Peer).

test_drop_on_down() ->
    Peer = spawn_link(fun() -> ?pending:register(testpid()) end),
    ?wait(Peer),
    ?chunks:assigned(0, 0, 1, Peer, testpid()),
    ?expect({chunk, {dropped, 0, 0, 1, Peer}}).

test_request_list() ->
    Main = self(),
    Pid = spawn_link(fun() ->
        ?pending:register(testpid()),
        ?chunks:assigned(0, 0, 1, self(), testpid()),
        ?chunks:assigned(0, 1, 1, self(), testpid()),
        Main ! assigned,
        etorrent_utils:expect(die)
    end),
    etorrent_utils:expect(assigned),
    Requests = ?chunks:requests(testpid()),
    Pid ! die, etorrent_utils:wait(Pid),
    ?assertEqual([{Pid,{0,0,1}}, {Pid,{0,1,1}}], lists:sort(Requests)).

-endif.

-ifdef(TEST2).

infohash_test_() ->
    FileName =
    filename:join(code:lib_dir(etorrent_core),
                  "test/etorrent_eunit_SUITE_data/test_file_30M.random.torrent"),
    [?_assertEqual({ok, "87be033150bd8dd1801478a32d4c79e54cb55552"}, 
                   ?MODULE:info_hash(FileName))].


%% @private Update dotdir configuration parameter to point to a new directory.
setup_config() ->
    Dir = test_server:temp_name("/tmp/etorrent."),
    ok = meck:new(etorrent_config, []),
    ok = meck:expect(etorrent_config, dotdir, fun () -> Dir end).

%% @private Delete the directory pointed to by the dotdir configuration parameter.
teardown_config(_) ->
    %% @todo Recursive file:delete.
    ok = meck:unload(etorrent_config).

testpath() ->
    "../" "../" "../"
    "test/" "etorrent_eunit_SUITE_data/debian-6.0.2.1-amd64-netinst.iso.torrent".

testhex()  -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4".
testinfo() -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4.info".


dotfiles_test_() ->
    {setup,local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end, [
        {foreach,local, 
            fun setup_config/0,
            fun teardown_config/1, [
            ?_test(test_no_torrents()),
            ?_test(test_ensure_exists()),
            test_ensure_exists_error_()] ++
            [{setup,local,
                fun() -> ?MODULE:make() end,
                fun(_) -> ok end,
                [T]} || T <- [
                ?_test(test_copy_torrent()),
                test_copy_torrent_error_(),
                ?_test(test_info_filename()),
                ?_test(test_info_hash()),
                ?_test(test_read_torrent()),
                ?_test(test_read_info()),
                ?_test(test_write_info())]]
        }
    ]}.

test_no_torrents() ->
    ?assertEqual({error, enoent}, ?MODULE:torrents()).

test_ensure_exists() ->
    ?assertNot(?MODULE:exists(etorrent_config:dotdir())),
    ok = ?MODULE:make(),
    ?assert(?MODULE:exists(etorrent_config:dotdir())).

test_ensure_exists_error_() ->
    {setup,
        _Setup=fun() ->
        ok = meck:new(file, [unstick,passthrough]),
        ok = meck:expect(file, read_file_info, fun(_) -> {error, enoent} end),
        ok = meck:expect(file, make_dir, fun(_) -> {error, eacces} end)
        end,
        _Teardown=fun(_) -> 
        meck:unload(file)
        end,
        {inorder, [
            ?_assertEqual({error, eacces}, ?MODULE:make()),
            ?_assert(meck:validate(file))]}}.

test_copy_torrent() ->
    ?assertEqual({ok, testhex()}, ?MODULE:copy_torrent(testpath())),
    ?assertEqual({ok, [testhex()]}, ?MODULE:torrents()).

test_copy_torrent_error_() ->
     {setup,
        _Setup=fun() ->
        ok = meck:new(file, [unstick,passthrough]),
        ok = meck:expect(file, copy, fun(_, _) -> {error, eacces} end)
        end,
        _Teardown=fun(_) -> 
        meck:unload(file)
        end,
        {inorder, [
            ?_assertEqual({error, eacces}, ?MODULE:copy_torrent(testpath())),
            ?_assertEqual({ok, []}, ?MODULE:torrents()),
            ?_assert(meck:validate(file))]}}.
   

test_info_filename() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    ?assertEqual(testinfo(), lists:last(filename:split(?MODULE:info_path(Infohash)))).

test_info_hash() ->
    ?assertEqual({ok, testhex()}, ?MODULE:info_hash(testpath())).

test_read_torrent() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    {ok, Metadata} = ?MODULE:read_torrent(Infohash),
    RawInfohash = etorrent_metainfo:get_infohash(Metadata),
    ?assertEqual(Infohash, info_hash_to_hex(RawInfohash)).

test_read_info() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    {error, enoent} = ?MODULE:read_info(Infohash).

test_write_info() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    ok = ?MODULE:write_info(Infohash, [{<<"a">>, 1}]),
    {ok, [{<<"a">>, 1}]} = ?MODULE:read_info(Infohash).


-endif.



-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(state, ?MODULE).
-define(pset, etorrent_pieceset).
-define(rqueue, etorrent_rqueue).

testsize() -> 8.

defaults_test_() ->
    State = ?state:new(testsize()),
    [?_assert(?state:choked(State)),
     ?_assertNot(?state:interested(State)),
     ?_assertNot(?state:seeder(State)),
     ?_assertEqual(0, ?rqueue:size(?state:requests(State))),
     ?_assertNot(?state:needreqs(State)),
     ?_assertError(badarg, ?state:pieces(State)),
     ?_assertError(badarg, ?state:interesting(0, State))].

initset_test_() ->
    State = ?state:new(testsize()),
    P0 = ?state:pieces(?state:hasone(0, State)),
    P1 = ?state:pieces(?state:hasset(<<1:1, 0:7>>, State)),
    P2 = ?state:pieces(?state:hasall(State)),
    P3 = ?state:pieces(?state:hasnone(State)),
    [?_assertEqual(?pset:from_list([0], testsize()), P0),
     ?_assertEqual(?pset:from_list([0], testsize()), P1),
     ?_assertEqual(?pset:from_list([0,1,2,3,4,5,6,7], testsize()), P2),
     ?_assertEqual(?pset:from_list([], testsize()), P3)].

immutable_set_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:hasnone(S0),
    [?_assertError(badarg, ?state:hasset(<<1:1, 0:7>>, S1)),
     ?_assertError(badarg, ?state:hasall(S1)),
     ?_assertError(badarg, ?state:hasnone(S1)),
     ?_assertEqual(?state:hasone(0, S0), ?state:hasone(0, S1))].

seeder_revert_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:seeder(true, S0),
    [?_assert(?state:seeder(S1)),
     ?_assertError(badarg, ?state:seeder(false, S1))].

consistent_choked_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:choked(false, S0),
    [?_assertError(badarg, ?state:choked(true, S0)),
     ?_assertError(badarg, ?state:choked(false, S1)),
     ?_assertNot(?state:choked(S1))].

consistent_interested_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:interested(true, S0),
    [?_assertError(badarg, ?state:interested(false, S0)),
     ?_assertError(badarg, ?state:interested(true, S1)),
     ?_assert(?state:interested(S1))].

interesting_received_test_() ->
    S0 = ?state:new(testsize()),
    S1 = ?state:hasone(7, S0),
    S2 = ?state:interested(true, S1),
    [?_assertEqual(S1, ?state:interesting(7, S1)),
     ?_assert(?state:interested(?state:interesting(6, S1))),
     ?_assertEqual(S2, ?state:interesting(7, S2)),
     ?_assertEqual(S2, ?state:interesting(6, S2))].

interesting_sent_test_() ->
    L0 = ?state:interested(true, ?state:hasnone(?state:new(testsize()))),
    L1 = ?state:hasone(0, L0),
    L2 = ?state:hasone(1, L1),
    L3 = ?state:interested(false, L1),

    R0 = ?state:hasnone(?state:new(testsize())),
    R1 = ?state:hasone(0, R0),
    R2 = ?state:hasone(1, R1),

    [?_assertEqual(L1, ?state:interesting(0, R0, L1)),
     ?_assertNot(?state:interested(?state:interesting(0, R1, L1))),
     ?_assertEqual(L1, ?state:interesting(0, R2, L1)),
     ?_assertNot(?state:interested(?state:interesting(0, R2, L2))),
     ?_assertEqual(L3, ?state:interesting(0, R1, L3))].

seeding_test_() ->
    S0 = ?state:new(testsize()),
    [?_assert(?state:seeding(?state:hasall(S0))),
     ?_assertNot(?state:seeding(?state:hasnone(S0))),
     ?_assertNot(?state:seeding(?state:hasone(0, S0)))].

needreq_test_() ->
    S0 = ?state:hasnone(?state:new(testsize())),
    S1 = ?state:interested(true, S0),
    S2 = ?state:choked(false, S0),
    S3 = ?state:interested(true, ?state:choked(false, S0)),
    [?_assertNot(?state:needreqs(S0)),
     ?_assertNot(?state:needreqs(S1)),
     ?_assertNot(?state:needreqs(S2)),
     ?_assert(?state:needreqs(S3))].

request_update_test() ->
    S0 = ?state:hasnone(?state:new(testsize())),
    Reqs = ?state:requests(S0),
    NewReqs = ?rqueue:push(0, 0, 1, Reqs),
    S1 = ?state:requests(NewReqs, S0),
    ?assertEqual(NewReqs, ?state:requests(S1)).

-endif.

-ifdef(TEST2).
filter_supported_test_() ->
    [?_assertEqual([{x,{1,yy}},{y,{2,zz}}],
                   filter_supported([{<<"x">>,1}, {<<"y">>,2}, {<<"z">>,3}],
                                    [<<"a">>,<<"x">>,<<"y">>],
                                    [xx,yy,zz]))
    ,?_assertEqual([],
                   filter_supported([],
                                    [<<"a">>],
                                    [xx]))
    ].
-endif.


-ifdef(TEST2).
update_ord_dict_test_() ->
    [{"Add 3 new extensions."
    ,?_assertEqual(update_ord_dict([{<<"x">>,1}, {<<"y">>,2}, {<<"z">>,3}],
                                    []),
                   [{<<"x">>,1}, {<<"y">>,2}, {<<"z">>,3}])}
    ,{"Add 2 new extension, ignore deletion of the one."
    ,?_assertEqual(update_ord_dict([{<<"x">>,1}, {<<"y">>,0}, {<<"z">>,3}],
                                    []),
                   [{<<"x">>,1}, {<<"z">>,3}])}
    ,{"Add 2 new extension, delete the one."
    ,?_assertEqual(update_ord_dict([{<<"x">>,1}, {<<"y">>,0}, {<<"z">>,3}],
                                    [{<<"y">>,2}]),
                   [{<<"x">>,1}, {<<"z">>,3}])}
%   ,{"Add 2 new extension to a non-empty list, and delete them (strange)."
%   ,?_assertEqual(update_ord_dict([{<<"x">>,1}, {<<"x">>,0}, {<<"z">>,3}, {<<"z">>,0}],
%                                   [{<<"y">>,2}]),
%                  [{<<"y">>,2}])}
    %% Strange case.
    ,{"Delete new extension, and add it."
    ,?_assertEqual(update_ord_dict([{<<"x">>,0}, {<<"x">>,3}],
                                    [{<<"y">>,2}]),
                   [{<<"x">>,3}, {<<"y">>,2}])}
    ].
-endif.

-ifdef(EUNIT).
-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.


-define(utils, ?MODULE).

find_nomatch_test() ->
    False = fun(_) -> false end,
    ?assertEqual(false, ?utils:find(False, [1,2,3])).

find_match_test() ->
    Last = fun(E) -> E == 3 end,
    ?assertEqual(3, ?utils:find(Last, [1,2,3])).

reply_test() ->
    Pid = spawn_link(fun() ->
        ?utils:reply(fun(call) -> reply end)
    end),
    ?assertEqual(reply, gen_server:call(Pid, call)).

register_test_() ->
    {setup,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end,
    [?_test(test_register()),
     ?_test(test_register_group())
    ]}.

test_register() ->
    true = ?utils:register(name),
    ?assertEqual(self(), ?utils:lookup(name)),
    ?assertEqual(self(), ?utils:await(name)).

test_register_group() ->
    ?assertEqual([], ?utils:lookup_members(group)),
    true = ?utils:register_member(group),
    ?assertEqual([self()], ?utils:lookup_members(group)),
    Main = self(),
    Pid = spawn_link(fun() ->
        ?utils:register_member(group),
        Main ! registered,
        ?utils:expect(die)
    end),
    ?utils:expect(registered),
    ?assertEqual([self(),Pid], lists:sort(?utils:lookup_members(group))),
    ?utils:unregister_member(group),
    ?assertEqual([Pid], ?utils:lookup_members(group)),
    Pid ! die, ?utils:wait(Pid),
    ?utils:ping(whereis(gproc)),
    ?assertEqual([], ?utils:lookup_members(group)).

groupby_duplicates_test() ->
    Inp = [c, a, b, c, a, b],
    Exp = [{a, [a,a]}, {b, [b,b]}, {c, [c,c]}],
    Fun = fun(E) -> {E, E} end,
    ?assertEqual(Exp, ?utils:group(Fun, Inp)).

-ifdef(PROPER).

prop_gsplit_split() ->
    ?FORALL({N, Ls}, {nat(), list(int())},
	    if
		N >= length(Ls) ->
		    {Ls, []} =:= gsplit(N, Ls);
		true ->
		    lists:split(N, Ls) =:= gsplit(N, Ls)
	    end).

prop_group_count() ->
    ?FORALL(Ls, list(int()),
	    begin
		Sorted = lists:sort(Ls),
		Grouped = group(Sorted),
		lists:all(
		  fun({Item, Count}) ->
			  length([E || E <- Ls,
				       E =:= Item]) == Count
		  end,
		  Grouped)
	    end).

shuffle_list(List) ->
    init_random_generator(),
    {NewList, _} = lists:foldl( fun(_El, {Acc,Rest}) ->
        RandomEl = lists:nth(random:uniform(length(Rest)), Rest),
        {[RandomEl|Acc], lists:delete(RandomEl, Rest)}
    end, {[],List}, List),
    NewList.

proplist_utils_test() ->
    Prop1 = lists:zip(lists:seq(1, 15), lists:seq(1, 15)),
    Prop2 = lists:zip(lists:seq(5, 20), lists:seq(5, 20)),
    PropFull = lists:zip(lists:seq(1, 20), lists:seq(1, 20)),
    ?assertEqual(merge_proplists(shuffle_list(Prop1), shuffle_list(Prop2)),
                 PropFull),
    ?assert(compare_proplists(Prop1, shuffle_list(Prop1))),
    ok.

eqc_count_test() ->
    ?assert(proper:quickcheck(prop_group_count())).

eqc_gsplit_test() ->
    ?assert(proper:quickcheck(prop_gsplit_split())).

-endif.
-endif.
-ifdef(EUNIT).

base32_binary_to_integer_test_() ->
    [?_assertEqual(base32_binary_to_integer(<<"IXE2K3JMCPUZWTW3YQZZOIB5XD6KZIEQ">>),
                   398417223648295740807581630131068684170926268560)
    ].

-endif.
-ifdef(TEST2).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-define(PROPER_NO_IMPORTS, true).
-include_lib("proper/include/proper.hrl").
-endif.

-define(set, ?MODULE).

%% The highest bit in the first byte corresponds to piece 0.
high_bit_test() ->
    Set = ?set:from_binary(<<1:1, 0:7>>, 8),
    ?assert(?set:is_member(0, Set)).

%% And the bit after that corresponds to piece 1.
bit_order_test() ->
    Set = ?set:from_binary(<<1:1, 1:1, 0:6>>, 8),
    ?assert(?set:is_member(0, Set)),
    ?assert(?set:is_member(1, Set)).

%% The lowest bit in the first byte corresponds to piece 7,
%% and the highest bit in the second byte corresponds to piece 8.
byte_boundry_test() ->
    Set = ?set:from_binary(<<0:7, 1:1, 1:1, 0:7>>, 16),
    ?assert(?set:is_member(7, Set)),
    ?assert(?set:is_member(8, Set)).

%% The remaining bits should be padded with zero and ignored
padding_test() ->
    Set = ?set:from_binary(<<0:8, 0:6, 1:1, 0:1>>, 15),
    ?assert(?set:is_member(14, Set)),
    ?assertError(badarg, ?set:is_member(15, Set)).

%% If the padding is invalid, the conversion from
%% bitfield to pieceset should crash.
invalid_padding_test() ->
    ?assertError(badarg, ?set:from_binary(<<0:7, 1:1>>, 7)).

%% Piece indexes can never be less than zero
negative_index_test() ->
    ?assertError(badarg, ?set:is_member(-1, undefined)).

%% Piece indexes that fall outside of the index range should fail
too_high_member_test() ->
    Set = ?set:new(8),
    ?assertError(badarg, ?set:is_member(8, Set)).

%% An empty piece set should contain 0 pieces
empty_size_test() ->
    ?assertEqual(0, ?set:size(?set:new(8))),
    ?assertEqual(0, ?set:size(?set:new(14))).

full_size_test() ->
    Set0 = ?set:from_binary(<<255:8>>, 8),
    ?assertEqual(8, ?set:size(Set0)),
    Set1 = ?set:from_binary(<<255:8, 1:1, 0:7>>, 9),
    ?assertEqual(9, ?set:size(Set1)).

%% An empty set should be converted to an empty list
empty_list_test() ->
    Set = ?set:new(8),
    ?assertEqual([], ?set:to_list(Set)).

%% Expect the list to be ordered from smallest to largest
list_order_test() ->
    Set = ?set:from_binary(<<1:1, 0:7, 1:1, 0:7>>, 9),
    ?assertEqual([0,8], ?set:to_list(Set)).

%% Expect an empty list to be converted to an empty set
from_empty_list_test() ->
    Set0 = ?set:new(8),
    Set1 = ?set:from_list([], 8),
    ?assertEqual(Set0, Set1).

from_full_list_test() ->
    Set0 = ?set:from_binary(<<255:8>>, 8),
    Set1 = ?set:from_list(lists:seq(0,7), 8),
    ?assertEqual(Set0, Set1).

min_test_() ->
    [?_assertError(badarg, ?set:min(?set:new(20))),
     ?_assertEqual(0, ?set:min(?set:from_list([0], 8))),
     ?_assertEqual(1, ?set:min(?set:from_list([1,7], 8))),
     ?_assertEqual(15, ?set:min(?set:from_list([15], 16)))].

first_test_() ->
    Set = ?set:from_list([0,1,2,4,8,16,17], 18),
    [?_assertEqual(0, ?set:first([0,1], Set)),
     ?_assertEqual(1, ?set:first([1,0], Set)),
     ?_assertEqual(17, ?set:first([17,0,1], Set)),
     ?_assertError(badarg, ?set:first([9,15], Set))].

%%
%% Modifying the contents of a pieceset
%%

%% Piece indexes can never be less than zero.
negative_index_insert_test() ->
    ?assertError(badarg, ?set:insert(-1, undefined)).

%% Piece indexes should be within the range of the piece set
too_high_index_test() ->
    Set = ?set:new(8),
    ?assertError(badarg, ?set:insert(8, Set)).

%% The index of the last piece should work though
max_index_test() ->
    Set = ?set:new(8),
    ?assertMatch(_, ?set:insert(7, Set)).

%% Inserting a piece into a piece set should make it a member of the set
insert_min_test() ->
    Init = ?set:new(8),
    Set  = ?set:insert(0, Init),
    ?assert(?set:is_member(0, Set)),
    ?assertEqual(<<1:1, 0:7>>, ?set:to_binary(Set)).

insert_max_min_test() ->
    Init = ?set:new(5),
    Set  = ?set:insert(0, ?set:insert(4, Init)),
    ?assert(?set:is_member(4, Set)),
    ?assert(?set:is_member(0, Set)),
    ?assertEqual(<<1:1, 0:3, 1:1, 0:3>>, ?set:to_binary(Set)).

delete_invalid_index_test() ->
    Set = ?set:new(3),
    ?assertError(badarg, ?set:delete(-1, Set)),
    ?assertError(badarg, ?set:delete(3, Set)).

delete_test() ->
    Set = ?set:from_list([0,2], 3),
    ?assertNot(?set:is_member(0, ?set:delete(0, Set))),
    ?assertNot(?set:is_member(2, ?set:delete(2, Set))).

intersection_size_test() ->
    Set0 = ?set:new(5),
    Set1 = ?set:new(6),
    ?assertError(badarg, ?set:intersection(Set0, Set1)).

intersection_test() ->
    Set0  = ?set:from_binary(<<1:1, 0:7,      1:1, 0:7>>, 16),
    Set1  = ?set:from_binary(<<1:1, 1:1, 0:6, 1:1, 0:7>>, 16),
    Inter = ?set:intersection(Set0, Set1),
    Bitfield = <<1:1, 0:1, 0:6, 1:1, 0:7>>,
    ?assertEqual(Bitfield, ?set:to_binary(Inter)).

difference_size_test() ->
    Set0 = ?set:new(5),
    Set1 = ?set:new(6),
    ?assertError(badarg, ?set:difference(Set0, Set1)).

difference_test() ->
    Set0  = ?set:from_list([0,1,    4,5,6,7], 8),
    Set1  = ?set:from_list([  1,2,3,4,  6,7], 8),
    Inter = ?set:difference(Set0, Set1),
    ?assertEqual([0,5], ?set:to_list(Inter)).

%%
%% Conversion from piecesets to bitfields should produce valid bitfields.
%%

%% Starting from bit 0.
piece_0_test() ->
    Bitfield = <<1:1, 0:7>>,
    Set = ?set:from_binary(Bitfield, 8),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).

%% Continuing into the second byte with piece 8.
piece_8_test() ->
    Bitfield = <<1:1, 0:7, 1:1, 0:7>>,
    Set = ?set:from_binary(Bitfield, 16),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).

%% Preserving the original padding of the bitfield.
pad_binary_test() ->
    Bitfield = <<1:1, 1:1, 1:1, 0:5>>,
    Set = ?set:from_binary(Bitfield, 4),
    ?assertEqual(Bitfield, ?set:to_binary(Set)).

%% An empty pieceset should include the number of pieces
empty_pieceset_string_test() ->
    ?assertEqual("<pieceset(8) []>", ?set:to_string(?set:empty(8))).

one_element_pieceset_string_test() ->
    ?assertEqual("<pieceset(8) [0]>", ?set:to_string(?set:from_list([0], 8))).

two_element_0_pieceset_string_test() ->
    ?assertEqual("<pieceset(8) [0,2]>", ?set:to_string(?set:from_list([0,2], 8))).

two_element_1_pieceset_string_test() ->
    ?assertEqual("<pieceset(16) [0,15]>", ?set:to_string(?set:from_list([0,15], 16))).

three_element_pieceset_string_test() ->
    ?assertEqual("<pieceset(8) [0,2,7]>", ?set:to_string(?set:from_list([0,2,7], 8))).

two_element_range_string_test() ->
    ?assertEqual("<pieceset(8) [0-1]>", ?set:to_string(?set:from_list([0,1], 8))).

three_element_range_string_test() ->
    ?assertEqual("<pieceset(8) [0-2]>", ?set:to_string(?set:from_list([0,1,2], 8))).

ranges_string_test() ->
    ?assertEqual("<pieceset(8) [0,2-3,5-7]>", ?set:to_string(?set:from_list([0,2,3,5,6,7], 8))).



-ifdef(PROPER).
prop_min() ->
    ?FORALL({Elem, Size},
    ?SUCHTHAT({E, S}, {non_neg_integer(), pos_integer()}, E < S),
    begin
        Elem == ?set:min(?set:from_list([Elem], Size))
    end).

prop_full() ->
    ?FORALL(Size, pos_integer(),
    begin
        All = lists:seq(0, Size - 1),
        Set = ?set:from_list(All, Size),
        ?set:is_full(Set)
    end).

prop_not_full() ->
    ?FORALL({Elem, Size},
    ?SUCHTHAT({E, S}, {non_neg_integer(), pos_integer()}, E < S),
    begin
        All = lists:seq(0, Size - 1),
        Not = lists:delete(Elem, All),
        Set = ?set:from_list(Not, Size),
        not ?set:is_full(Set)
    end).

prop_min_test() ->
    ?assertEqual(true, proper:quickcheck(prop_min())).

prop_full_test() ->
    ?assertEqual(true, proper:quickcheck(prop_full())).

prop_not_full_test() ->
    ?assertEqual(true, proper:quickcheck(prop_not_full())).

-endif.
-endif.
-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(rqueue, etorrent_rqueue).

empty_test_() ->
    Q0 = ?rqueue:new(),
    [?_assertEqual(0, ?rqueue:size(Q0)),
     ?_assertError(badarg, ?rqueue:pop(Q0)),
     ?_assertEqual(false, ?rqueue:peek(Q0)),
     ?_assertNot(?rqueue:is_head(0, 0, 0, Q0)),
     ?_assertNot(?rqueue:has_offset(0, 0, Q0)),
     ?_assertEqual([], ?rqueue:to_list(Q0))].

one_request_test_() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:pop(Q1),
    [?_assertEqual(1, ?rqueue:size(Q1)),
     ?_assertEqual({0,0,1}, ?rqueue:peek(Q1)),
     ?_assertEqual([{0,0,1}], ?rqueue:to_list(Q1)),
     ?_assertEqual([], ?rqueue:to_list(Q2)),
     ?_assertEqual(0, ?rqueue:size(?rqueue:flush(Q1)))].

head_check_test_() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(1, 2, 3, Q0),
    [?_assertNot(?rqueue:is_head(1, 2, 3, Q0)),
     ?_assert(?rqueue:is_head(1, 2, 3, Q1)),
     ?_assertNot(?rqueue:is_head(1, 2, 2, Q1)),
     ?_assertNot(?rqueue:is_head(1, 2, 4, Q1)),
     ?_assert(?rqueue:has_offset(1, 2, Q1)),
     ?_assertNot(?rqueue:has_offset(0, 2, Q1)),
     ?_assertNot(?rqueue:has_offset(1, 1, Q1))].

low_check_test_() ->
    Q0 = ?rqueue:new(1, 3),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push(0, 1, 1, Q1),
    [?_assert(?rqueue:is_low(Q0)),
     ?_assert(?rqueue:is_low(Q1)),
     ?_assertNot(?rqueue:is_low(Q2)),
     ?_assertEqual({low, 3}, ?rqueue:view(Q0)),
     ?_assertEqual({low, 2}, ?rqueue:view(Q1)),
     ?_assertEqual({needs, 1}, ?rqueue:view(Q2))
     ].

needs_test_() ->
    Q0 = ?rqueue:new(1, 3),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push(0, 1, 1, Q1),
    Q3 = ?rqueue:push(0, 2, 1, Q2),
    Q4 = ?rqueue:push(0, 3, 1, Q3),
    [?_assertEqual(3, ?rqueue:needs(Q0)),
     ?_assertEqual(2, ?rqueue:needs(Q1)),
     ?_assertEqual(1, ?rqueue:needs(Q2)),
     ?_assertEqual(0, ?rqueue:needs(Q3)),
     ?_assertEqual(full, ?rqueue:view(Q3)),
     ?_assertEqual(0, ?rqueue:needs(Q4)),
     ?_assertEqual({over_limit, 1}, ?rqueue:view(Q4))].

high_check_test_() ->
    Q0 = ?rqueue:new(1, 3),
    Q1 = ?rqueue:push([null], Q0),
    Q3 = ?rqueue:push([null, null, null], Q0),
    Q4 = ?rqueue:push([null, null, null, null], Q0),
    [?_assertEqual(false, ?rqueue:is_overlimit(Q0)),
     ?_assertEqual({low, 3}, ?rqueue:view(Q0)),
     ?_assertEqual(false, ?rqueue:is_overlimit(Q1)),
     ?_assertEqual({low, 2}, ?rqueue:view(Q1)),
     ?_assertEqual(true,  ?rqueue:is_overlimit(Q3)),
     ?_assertEqual(full, ?rqueue:view(Q3)),
     ?_assertEqual(true,  ?rqueue:is_overlimit(Q4)),
     ?_assertEqual({over_limit, 1}, ?rqueue:view(Q4))].

push_list_test_() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push([{0,1,1},{0,2,1}], Q1),
    OQ0 = ?rqueue:pop(Q2),
    OQ1 = ?rqueue:pop(OQ0),
    OQ2 = ?rqueue:pop(OQ1),
    [?_assertEqual({0,0,1}, ?rqueue:peek(Q2)),
     ?_assertEqual({0,1,1}, ?rqueue:peek(OQ0)),
     ?_assertEqual({0,2,1}, ?rqueue:peek(OQ1)),
     ?_assertEqual([{0,0,1},{0,1,1},{0,2,1}], ?rqueue:to_list(Q2)),
     ?_assertEqual([], ?rqueue:to_list(OQ2))].

member_delete_test() ->
    Q0 = ?rqueue:new(),
    Q1 = ?rqueue:push(0, 0, 1, Q0),
    Q2 = ?rqueue:push(0, 1, 1, Q1),
    ?assert(?rqueue:member(0, 0, 1, Q1)),
    ?assertNot(?rqueue:member(0, 1, 1, Q1)),
    ?assert(?rqueue:member(0, 1, 1, Q2)),
    Q3 = ?rqueue:delete(0, 1, 1, Q2),
    ?assertNot(?rqueue:member(0, 1, 1, Q3)),
    ?assert(?rqueue:member(0, 0, 1, Q3)),
    Q4 = ?rqueue:delete(0, 0, 1, Q3),
    ?assertNot(?rqueue:member(0, 0, 1, Q4)).

-endif.

-ifdef(TEST2).
-define(progress, ?MODULE).
-define(scarcity, etorrent_scarcity).
-define(timer, etorrent_timer).
-define(pending, etorrent_pending).
-define(chunkstate, etorrent_chunkstate).
-define(piecestate, etorrent_piecestate).
-define(endgame, etorrent_endgame).

chunk_server_test_() ->
    {setup, local,
        fun() ->
            application:start(gproc),
            etorrent_torrent_ctl:register_server(testid()) end,
        fun(_) -> application:stop(gproc) end,
    {foreach, local,
        fun setup_env/0,
        fun teardown_env/1,
    [?_test(lookup_registered_case()),
     ?_test(unregister_case()),
     ?_test(register_two_case()),
     ?_test(double_check_env()),
     ?_test(assigned_case()),
     ?_test(assigned_valid_case()),
     ?_test(request_one_case()),
     ?_test(mark_dropped_case()),
     ?_test(mark_all_dropped_case()),
     ?_test(drop_none_on_exit_case()),
     ?_test(drop_all_on_exit_case()),
     ?_test(marked_stored_not_dropped_case()),
     ?_test(mark_valid_not_stored_case()),
     ?_test(mark_valid_stored_case()),
     ?_test(all_stored_marks_stored_case()),
     ?_test(get_all_request_case()),
     ?_test(unassigned_to_assigned_case()),
     ?_test(trigger_endgame_case())
     ]}}.


testid() -> 2.

setup_env() ->
    Sizes = [{0, 2}, {1, 2}, {2, 2}],
    Valid = etorrent_pieceset:empty(length(Sizes)),
    Wishes = [],
    {ok, Time} = ?timer:start_link(queue),
    {ok, PPid} = ?pending:start_link(testid()),
    {ok, EPid} = ?endgame:start_link(testid()),
    {ok, SPid} = ?scarcity:start_link(testid(), Time, 8),
    {ok, CPid} = ?progress:start_link(testid(), 1, Valid, Sizes, self(), Wishes),
    ok = ?pending:register(PPid),
    ok = ?pending:receiver(CPid, PPid),
    {Time, EPid, PPid, SPid, CPid}.

scarcity() -> ?scarcity:lookup_server(testid()).
pending()  -> ?pending:lookup_server(testid()).
progress() -> ?progress:lookup_server(testid()).
endgame()  -> ?endgame:lookup_server(testid()).

teardown_env({Time, EPid, PPid, SPid, CPid}) ->
    ok = etorrent_utils:shutdown(Time),
    ok = etorrent_utils:shutdown(EPid),
    ok = etorrent_utils:shutdown(PPid),
    ok = etorrent_utils:shutdown(SPid),
    ok = etorrent_utils:shutdown(CPid).

double_check_env() ->
    ?assert(is_pid(scarcity())),
    ?assert(is_pid(pending())),
    ?assert(is_pid(progress())),
    ?assert(is_pid(endgame())).

lookup_registered_case() ->
    ?assertEqual(true, ?progress:register_server(0)),
    ?assertEqual(self(), ?progress:lookup_server(0)).

unregister_case() ->
    ?assertEqual(true, ?progress:register_server(1)),
    ?assertEqual(true, ?progress:unregister_server(1)),
    ?assertError(badarg, ?progress:lookup_server(1)).

register_two_case() ->
    Main = self(),
    {Pid, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        true = ?pending:register_server(20),
        Main ! registered,
        etorrent_utils:expect(die)
    end),
    Pid ! go,
    etorrent_utils:expect(registered),
    ?assertError(badarg, ?pending:register_server(20)),
    Pid ! die,
    etorrent_utils:wait(Ref).

assigned_case() ->
    Has = etorrent_pieceset:from_list([], 3),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, assigned}, Ret).

assigned_valid_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    _   = ?chunkstate:request(2, Has, progress()),
    ok  = ?chunkstate:stored(0, 0, 1, self(), progress()),
    ok  = ?chunkstate:stored( 0, 1, 1, self(), progress()),
    ok  = ?piecestate:valid(0, progress()),
    Ret = ?chunkstate:request(2, Has, progress()),
    ?assertEqual({ok, assigned}, Ret).

request_one_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ok  = ?chunkstate:dropped(0, 0, 1, self(), progress()),
    Ret = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, [{0, 0, 1}]}, Ret).

mark_all_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())),
    ok = ?chunkstate:dropped(self(), pending()),
    ok = ?chunkstate:dropped([{0,0,1},{0,1,1}], self(), progress()),
    etorrent_utils:ping(pending()),
    etorrent_utils:ping(progress()),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

drop_all_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending()),
        {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
        {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress())
    end),
    etorrent_utils:wait(Pid),
    timer:sleep(100),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

drop_none_on_exit_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending())
    end),
    etorrent_utils:wait(Pid),
    ?assertMatch({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

marked_stored_not_dropped_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    Pid = spawn_link(fun() ->
        ok = ?pending:register(pending()),
        {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
        ok = ?chunkstate:stored(0, 0, 1, self(), progress()),
        ok = ?chunkstate:stored(0, 0, 1, self(), pending())
    end),
    etorrent_utils:wait(Pid),
    ?assertMatch({ok, [{0, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

mark_valid_not_stored_case() ->
    Ret = ?piecestate:valid(0, progress()),
    ?assertEqual(ok, Ret).

mark_valid_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ok  = ?chunkstate:stored(0, 0, 1, self(), progress()),
    ok  = ?chunkstate:stored(0, 1, 1, self(), progress()),
    ?assertEqual(ok, ?piecestate:valid(0, progress())),
    ?assertEqual(ok, ?piecestate:valid(0, progress())).

all_stored_marks_stored_case() ->
    Has = etorrent_pieceset:from_list([0,1], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ?assertMatch({ok, [{1, 0, 1}]}, ?chunkstate:request(1, Has, progress())),
    ?assertMatch({ok, [{1, 1, 1}]}, ?chunkstate:request(1, Has, progress())).

get_all_request_case() ->
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{0, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{1, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{1, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{2, 0, 1}]} = ?chunkstate:request(1, Has, progress()),
    {ok, [{2, 1, 1}]} = ?chunkstate:request(1, Has, progress()),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, progress())).

unassigned_to_assigned_case() ->
    Has = etorrent_pieceset:from_list([0], 3),
    {ok, [{0,0,1}, {0,1,1}]} = ?chunkstate:request(2, Has, progress()),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, progress())).

trigger_endgame_case() ->
    %% Endgame should be triggered if all pieces have been begun and all
    %% remaining chunk requests have been assigned to peer processes.
    Has = etorrent_pieceset:from_list([0,1,2], 3),
    {ok, [{0, 0, 1}, {0, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, [{1, 0, 1}, {1, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, [{2, 0, 1}, {2, 1, 1}]} = ?chunkstate:request(2, Has, progress()),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    ?assert(?endgame:is_active(endgame())),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    ?chunkstate:dropped(0, 0, 1, self(), progress()),
    {ok, assigned} = ?chunkstate:request(1, Has, progress()),
    %% Assert that we can aquire only this request from the endgame process
    ?assertEqual({ok, [{0, 0, 1}]}, ?chunkstate:request(1, Has, endgame())),
    ?assertEqual({ok, assigned}, ?chunkstate:request(1, Has, endgame())),
    %% Mark all requests as fetched.
    ok = ?chunkstate:fetched(0, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(0, 1, 1, self(), endgame()),
    ok = ?chunkstate:fetched(1, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(1, 1, 1, self(), endgame()),
    ok = ?chunkstate:fetched(2, 0, 1, self(), endgame()),
    ok = ?chunkstate:fetched(2, 1, 1, self(), endgame()),
    ?assertEqual(ok, etorrent_utils:ping(endgame())).


%% Directory Structure:
%%
%% Num     Path      Pieceset (indexing from 1)
%% --------------------------------------------
%%  0  /              [1-4]
%%  1  /Dir1          [1,2]
%%  2  /Dir1/File1    [1]
%%  3  /Dir1/File2    [2]
%%  4  /Dir2          [3,4]
%%  5  /Dir2/File3    [3,4]
%%
%% Check that wishlist [2, 1, 3] will be minimized to [2, 1]
minimize_masks_test_() ->
    Empty = etorrent_pieceset:new(4),
    Dir1  = etorrent_pieceset:from_bitstring(<<2#1100:4>>),
    File1 = etorrent_pieceset:from_bitstring(<<2#1000:4>>),
    File2 = etorrent_pieceset:from_bitstring(<<2#0100:4>>),
    Dir2 = File3 = etorrent_pieceset:from_bitstring(<<2#0011:4>>),

    Masks = [File1, Dir1, File2],
    Union = Empty,
    
    Masks1 = minimize_masks(Masks, Union, []),
    [?_assertEqual(Masks1, [File1,Dir1])
    ].

-endif.
-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").


sort_records_test_() ->
    Unsorted = [#torrent{id=1}, #torrent{id=3}, #torrent{id=2}],
    Sorted = sort_records(Unsorted),
    [R1, R2, R3] = Sorted,

    [?_assertEqual(R1#torrent.id, 1)
    ,?_assertEqual(R2#torrent.id, 2)
    ,?_assertEqual(R3#torrent.id, 3)
    ].

-endif.
-ifdef(TEST2).

first_tracker_id_test_() ->
    [?_assertEqual(10,
                   first_tracker_id([[{10,"http://bt3.rutracker.org/ann?uk=xxxxxxxxxx"}],
                                     [{11,"http://retracker.local/announce"}]]))
    ].

-endif.
-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").
-define(piecestate, ?MODULE).

%% @todo reuse
flush() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    [receive Msg -> Msg end || Msg <- Msgs].

piecestate_test_() ->
    {foreach,local,
        fun() -> flush() end,
        fun(_) -> flush() end,
        [?_test(test_notify_pid_list()),
         ?_test(test_notify_piece_list()),
         ?_test(test_invalid()),
         ?_test(test_unassigned()),
         ?_test(test_stored()),
         ?_test(test_valid())]}.

test_notify_pid_list() ->
    ?assertEqual(ok, ?piecestate:invalid(0, [self(), self()])),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()).

test_notify_piece_list() ->
    ?assertEqual(ok, ?piecestate:invalid([0,1], self())),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()),
    ?assertEqual({piece, {invalid, 1}}, etorrent_utils:first()).

test_invalid() ->
    ?assertEqual(ok, ?piecestate:invalid(0, self())),
    ?assertEqual({piece, {invalid, 0}}, etorrent_utils:first()).

test_unassigned() ->
    ?assertEqual(ok, ?piecestate:unassigned(0, self())),
    ?assertEqual({piece, {unassigned, 0}}, etorrent_utils:first()).

test_stored() ->
    ?assertEqual(ok, ?piecestate:stored(0, self())),
    ?assertEqual({piece, {stored, 0}}, etorrent_utils:first()).

test_valid() ->
    ?assertEqual(ok, ?piecestate:valid(0, self())),
    ?assertEqual({piece, {valid, 0}}, etorrent_utils:first()).

-endif.
-ifdef(EUNIT2).

test_torrent() ->
    [{<<"announce">>,
      <<"http://torrent.ubuntu.com:6969/announce">>},
     {<<"announce-list">>,
      [[<<"http://torrent.ubuntu.com:6969/announce">>],
       [<<"http://ipv6.torrent.ubuntu.com:6969/announce">>]]},
     {<<"comment">>,<<"Ubuntu CD releases.ubuntu.com">>},
     {<<"creation date">>,1286702721},
     {<<"info">>,
      [{<<"length">>,728754176},
       {<<"name">>,<<"ubuntu-10.10-desktop-amd64.iso">>},
       {<<"piece length">>,524288},
       {<<"pieces">>,
	<<34,129,182,214,148,202,7,93,69,98,198,49,204,47,61,
	  110>>}]}].

test_torrent_private() ->
    T = test_torrent(),
    I = [{<<"info">>, IL} || {<<"info">>, IL} <- T],
    H = T -- I,
    P = [{<<"info">>, IL ++ [{<<"private">>, 1}]} || {<<"info">>, IL} <- T],
    H ++ P.
      	  
get_http_urls_test() ->
    ?assertEqual([["http://torrent.ubuntu.com:6969/announce"],
		  ["http://ipv6.torrent.ubuntu.com:6969/announce"]],
		 get_http_urls(test_torrent())).

is_private_test() ->
    ?assertEqual(false, is_private(test_torrent())),
    ?assertEqual(true, is_private(test_torrent_private())).

-endif.
-ifdef(EUNIT2).

ext_msg_contents_test() ->
    Expected = <<"d1:mde1:pi1729e4:reqqi100e1:v20:Etorrent v-test-casee">>,
    Computed = extended_msg_contents(1729, <<"Etorrent v-test-case">>,
                                     100, {}, []),
    ?assertEqual(Expected, Computed).

-endif.
-ifdef(TEST2).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    put(nofile, test_server:temp_name("/tmp/etorrent_test")),
    put(empty,  test_server:temp_name("/tmp/etorrent_test")),
    put(valid,  test_server:temp_name("/tmp/etorrent_test")),
    put(testid, etorrent_dht:random_id()),
    ok = file:write_file(get(empty), <<>>),
    ok = dump_state(get(valid), get(testid), []).

teardown(_) ->
    file:delete(get(empty)),
    file:delete(get(valid)).

dht_state_test_() ->
    {setup, local,
        fun setup/0,
        fun teardown/1,
    [?_test(test_nofile()),
     ?_test(test_empty()),
     ?_test(test_valid())]}.

test_nofile() ->
    Return = load_state(get(nofile)),
    ?assertMatch({_, _}, Return),
    {ID, Nodes} = Return,
    ?assert(is_integer(ID)),
    ?assert(is_list(Nodes)).

test_empty() ->
    Return = load_state(get(empty)),
    ?assertMatch({_, _}, Return),
    {ID, Nodes} = Return,
    ?assert(is_integer(ID)),
    ?assert(is_list(Nodes)).

test_valid() ->
    Return = load_state(get(valid)),
    ?assertMatch({_, _}, Return),
    {ID, Nodes} = Return,
    ?assertEqual(get(testid), ID),
    ?assert(is_list(Nodes)).

-endif.




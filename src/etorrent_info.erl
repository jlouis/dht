% @author Uvarov Michail <arcusfelis@gmail.com>

%% uTorrent/3120 forms a torrent with unordered directories:
%% ["dir1/f1.flac", "dir2/f2.flac", "dir1/f1.log"]
%% Run for more information:
%% etorrent_bcoding:parse_file("test/etorrent_eunit_SUITE_data/malena.torrent").
%%
%% There can be directory duplicates.
-module(etorrent_info).
-behaviour(gen_server).

-define(AWAIT_TIMEOUT, 10*1000).
-define(DEFAULT_CHUNK_SIZE, 16#4000). % TODO - get this value from a configuration file
-define(METADATA_BLOCK_BYTE_SIZE, 16384). %% 16KiB (16384 Bytes) 

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


-export([start_link/2,
         register_server/1,
         lookup_server/1,
         await_server/1]).

-export([get_mask/2,
         get_mask/3,
         get_mask/4,
         mask_to_filelist/2,
         mask_to_size/2,
         tree_children/2,
         file_diff/2,
         minimize_filelist/2]).

%% Info API
-export([long_file_name/2,
         file_name/2,
         full_file_name/2,
         file_position/2,
         file_size/2,
         piece_size/1,
         piece_size/2,
         piece_count/1,
         chunk_size/1,
         is_private/1,
         magnet_link/1
        ]).

%% Metadata API (BEP-9)
-export([metadata_size/1,
         get_piece/2]).

-export([
	init/1,
	handle_cast/2,
	handle_call/3,
	handle_info/2,
	terminate/2,
	code_change/3]).


-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().
-type file_id() :: etorrent_types:file_id().
-type pieceset() :: etorrent_pieceset:t().

-define(ROOT_FILE_ID, 0).

-record(state, {
    info_hash :: non_neg_integer(),
    torrent_name :: binary(),
    tracker_tiers :: [[binary()]],
    torrent :: torrent_id(),
    static_file_info :: array(),
    directories :: [file_id()], %% usorted
    total_size :: non_neg_integer(),
    piece_size :: non_neg_integer(),
    chunk_size = ?DEFAULT_CHUNK_SIZE :: non_neg_integer(),
    piece_count :: non_neg_integer(),
    metadata_size :: non_neg_integer(),
    metadata_pieces :: tuple(),
    is_private :: boolean()
    }).


-record(file_info, {
    id :: file_id(),
    parent_id :: file_id() | undefined,
    %% Level of the node, root level is 0.
    level :: non_neg_integer(),
    %% Relative name, used in file_sup
    name :: string(),
    %% Label for nodes of cascadae file tree
    short_name :: binary(),
    type      = file :: directory | file,
    %% Sorted.
    children  = [] :: [file_id()],
    %% Ascenders of this node without root-node.
    %% The oldest parent is last.
    parents = [] :: [file_id()],
    % How many files are in this node?
    capacity  = 0 :: non_neg_integer(),
    size      = 0 :: non_neg_integer(),
    % byte offset from 0
    % for splited directories - the lowest position
    position  = 0 :: non_neg_integer(),
    %% [{Position, Size}]
    byte_ranges :: [{non_neg_integer(), non_neg_integer()}],
    %% Pieces, that contains parts of this file.
    pieces :: etorrent_pieceset:t(),
    %% Pieces, that contains parts of this file only.
    distinct_pieces :: etorrent_pieceset:t()
}).

%% @doc Start the File I/O Server
%% @end
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    gen_server:start_link(?MODULE, [TorrentID, Torrent], [{timeout,15000}]).



server_name(TorrentID) ->
    {etorrent, TorrentID, info}.


%% @doc
%% Register the current process as the directory server for
%% the given torrent.
%% @end
-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

%% @doc
%% Lookup the process id of the directory server responsible
%% for the given torrent. If there is no such server registered
%% this function will crash.
%% @end
-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

%% @doc
%% Wait for the directory server for this torrent to appear
%% in the process registry.
%% @end
-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID), ?AWAIT_TIMEOUT).


-spec get_mask(torrent_id(), file_id() | [file_id()]) -> pieceset().
get_mask(TorrentID, FileID) ->
    get_mask(TorrentID, FileID, true).


%% @doc Build a mask of the file in the torrent.
get_mask(TorrentID, FileID, IsGreedy)
    when is_integer(FileID), is_boolean(IsGreedy) ->
    DirPid = await_server(TorrentID),
    {ok, Mask} = gen_server:call(DirPid, {get_mask, FileID, IsGreedy}),
    Mask;

%% List of files with same priority.
get_mask(TorrentID, IdList, IsGreedy)
    when is_list(IdList), is_boolean(IsGreedy) ->
    true = lists:all(fun is_integer/1, IdList),
    DirPid = await_server(TorrentID),
    {ok, Mask} = gen_server:call(DirPid, {get_mask, IdList, IsGreedy}),
    Mask.
   
 
%% @doc Build a mask of the part of the file in the torrent.
get_mask(TorrentID, FileID, PartStart, PartSize)
    when PartStart >= 0, PartSize >= 0, 
            is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Mask} = gen_server:call(DirPid, {get_mask, FileID, PartStart, PartSize}),
    Mask.


%% @doc Returns ids of each file, all pieces of that are in the pieceset `Mask'.
mask_to_filelist(TorrentID, Mask) ->
    DirPid = await_server(TorrentID),
    {ok, List} = gen_server:call(DirPid, {mask_to_filelist, Mask}),
    List.

%% @doc Returns a size of the selected pieces in the pieceset in bytes.
-spec mask_to_size(TorrentID, Mask) -> Size when
    TorrentID :: torrent_id(),
    Mask      :: pieceset(),
    Size      :: non_neg_integer().
mask_to_size(TorrentID, Mask) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, {mask_to_size, Mask}),
    Size.

piece_size(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, piece_size),
    Size.

piece_size(TorrentID, PieceNum) when is_integer(TorrentID), is_integer(PieceNum) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, {piece_size, PieceNum}),
    Size.


chunk_size(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, chunk_size),
    Size.


piece_count(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Count} = gen_server:call(DirPid, piece_count),
    Count.


is_private(TorrentID) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, is_private),
    Size.


file_position(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Pos} = gen_server:call(DirPid, {position, FileID}),
    Pos.


file_size(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Size} = gen_server:call(DirPid, {size, FileID}),
    Size.

magnet_link(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Link} = gen_server:call(DirPid, magnet_link),
    Link.


-spec tree_children(torrent_id(), file_id()) -> [{atom(), term()}].
tree_children(TorrentID, FileID) when is_integer(TorrentID), is_integer(FileID) ->
    %% get children
    DirPid = await_server(TorrentID),
    {ok, Records} = gen_server:call(DirPid, {tree_children, FileID}),

    %% get valid pieceset
    CtlPid = etorrent_torrent_ctl:lookup_server(TorrentID),    
    {ok, Valid}    = etorrent_torrent_ctl:valid_pieces(CtlPid),
    {ok, Unwanted} = etorrent_torrent_ctl:unwanted_pieces(CtlPid),

    lists:map(fun(X) ->
            Pieces         = X#file_info.pieces,
            DisPieces      = X#file_info.distinct_pieces,
            SizeFP         = etorrent_pieceset:size(Pieces),
            SizeDisFP      = etorrent_pieceset:size(DisPieces),
            {SizeCheckFP, CheckPieces} = case SizeDisFP of
                    0 -> {SizeFP, Pieces};
                    _ -> {SizeDisFP, DisPieces}
                end,
            ValidFP        = etorrent_pieceset:intersection(Pieces, Valid),
            UnwantedFP     = etorrent_pieceset:intersection(CheckPieces, Unwanted),
            ValidSizeFP    = etorrent_pieceset:size(ValidFP),
            UnwantedSizeFP = etorrent_pieceset:size(UnwantedFP),
            [{id, X#file_info.id}
            ,{name, X#file_info.short_name}
            ,{size, X#file_info.size}
            ,{capacity, X#file_info.capacity}
            ,{is_leaf, (X#file_info.children == [])}
%           ,{is_downloaded, (ValidSizeFP =:= SizeFP)}
            ,{mode, atom_to_binary(file_mode(SizeCheckFP, UnwantedSizeFP), utf8)}
            ,{progress, ValidSizeFP / SizeFP}
            ]
        end, Records).


%% Example:
%%
%% ```
%% FilePLs = etorrent_info:tree_children(1, 0),
%% {FileDiffPLs, NewFilePLs}   = etorrent_info:file_diff(TorrentID, FilePLs),
%% {FileDiffPLs2, NewFilePLs2} = etorrent_info:file_diff(TorrentID, NewFilePLs).
%% '''
%%
%% where `NewFilePLs' is an updated and minimized version of `FilePLs',
%% `FilePLs' is either value from `tree_children' or `NewFilePLs'.
-spec file_diff(TorrentID, FilePLs) -> {FileDiffPLs, NewFilePLs} when
    TorrentID :: torrent_id(),
    FilePLs     :: [{term(), term()}],
    NewFilePLs  :: [{term(), term()}],
    FileDiffPLs :: [{term(), term()}].
             
file_diff(TorrentID, FilePLs) when is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    FileIDs = [pl_fetch_value(id, FilePL) || FilePL <- FilePLs],
    {ok, Records} = gen_server:call(DirPid, {files, FileIDs}),
    FileID_PL_Recs = lists:zip3(FileIDs, FilePLs, Records),

    %% get valid pieceset
    CtlPid = etorrent_torrent_ctl:lookup_server(TorrentID),    
    {ok, Valid}    = etorrent_torrent_ctl:valid_pieces(CtlPid),
    traverse_files(Valid, FileID_PL_Recs, [], []).


traverse_files(Valid, [{FileID, FilePL, Record}|Xs], Zs, Ys) ->
    Pieces         = Record#file_info.pieces,
    SizeFP         = etorrent_pieceset:size(Pieces),
    ValidFP        = etorrent_pieceset:intersection(Pieces, Valid),
    ValidSizeFP    = etorrent_pieceset:size(ValidFP),
    NewProgress    = ValidSizeFP / SizeFP, %% 0.0 .. 1.0
    OldProgress    = proplists:get_value(progress, FilePL),
    IsProgressChanged = not compare_floats(NewProgress, OldProgress),
    IsDownloaded      = compare_floats(NewProgress, 1.0),
    PL = [{id, FileID}, {progress, NewProgress}],
    if IsProgressChanged ->
        if IsDownloaded -> traverse_files(Valid, Xs, [PL|Zs], Ys);
                   true -> traverse_files(Valid, Xs, [PL|Zs], [FilePL|Ys])
        end;
        true ->
        if IsDownloaded -> traverse_files(Valid, Xs, Zs, Ys);
                   true -> traverse_files(Valid, Xs, Zs, [FilePL|Ys])
        end
    end;
traverse_files(_Valid, [], Zs, Ys) ->
    {lists:reverse(Zs), lists:reverse(Ys)}.


-spec file_mode(SizeCheckFP, UnwantedSizeFP) -> Mode when
    SizeCheckFP :: non_neg_integer(),
    UnwantedSizeFP :: non_neg_integer(),
    Mode :: partial | skip | download.

file_mode(_, 0) -> download; %% a whole file will be downloaded.
file_mode(X, X) -> skip;     %% nothing from the file will be downloaded.
file_mode(_, _) -> partial.  %% something from the directory will be downloaded.
    

%% @doc Form minimal version of the filelist with the same pieceset.
minimize_filelist(TorrentID, FileIds) when is_integer(TorrentID) ->
    SortedFiles = lists:sort(FileIds),
    DirPid = await_server(TorrentID),
    {ok, Ids} = gen_server:call(DirPid, {minimize_filelist, SortedFiles}),
    Ids.
    

%% @doc This name is used in cascadae wish view.
-spec long_file_name(torrent_id(), file_id() | [file_id()]) -> binary().
long_file_name(TorrentID, FileID) when is_integer(FileID) ->
    long_file_name(TorrentID, [FileID]);

long_file_name(TorrentID, FileID) when is_list(FileID), is_integer(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Name} = gen_server:call(DirPid, {long_file_name, FileID}),
    Name.


full_file_name(TorrentID, FileID) when is_integer(FileID), is_integer(TorrentID) ->
    RelName = file_name(TorrentID, FileID),
    FileServer = etorrent_io:lookup_file_server(TorrentID, RelName),
    {ok, Name} = etorrent_io_file:full_path(FileServer),
    Name.


%% @doc Convert FileID to relative file name.
file_name(TorrentID, FileID) when is_integer(FileID) ->
    DirPid = await_server(TorrentID),
    {ok, Name} = gen_server:call(DirPid, {file_name, FileID}),
    Name.
    

-spec metadata_size(torrent_id()) -> non_neg_integer().
metadata_size(TorrentID) ->
    DirPid = await_server(TorrentID),
    {ok, Len} = gen_server:call(DirPid, metadata_size),
    Len.

%% Piece is indexed from 0.
get_piece(TorrentID, PieceNum) when is_integer(PieceNum) ->
    DirPid = await_server(TorrentID),
    {ok, PieceData} = gen_server:call(DirPid, {get_piece, PieceNum}),
    PieceData.

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, Torrent]) ->
    lager:debug("Starting collect_static_file_info for ~p.", [TorrentID]),
    Info = collect_static_file_info(Torrent),
    lager:debug("Static info is collected for ~p.", [TorrentID]),

    {Static, PLen, TLen, Dirs} = Info,

    true = register_server(TorrentID),

    MetaInfo = etorrent_bcoding:get_value("info", Torrent),
    Name = iolist_to_binary(etorrent_bcoding:get_info_value("name", Torrent)),
    TrackerTiers = etorrent_metainfo:get_url(Torrent),
    %% Really? First decode, now encode...
    TorrentBin = iolist_to_binary(etorrent_bcoding:encode(MetaInfo)),
    MetadataSize = byte_size(TorrentBin),
    <<IntIH:160>> = etorrent_utils:sha(TorrentBin),

    InitState = #state{
        info_hash=IntIH,
        torrent_name=Name,
        tracker_tiers=TrackerTiers,
        torrent=TorrentID,
        static_file_info=Static,
        directories=Dirs,
        total_size=TLen, 
        piece_size=PLen,
        piece_count=byte_to_piece_count(TLen, PLen),
        metadata_size = MetadataSize,
        metadata_pieces = list_to_tuple(metadata_pieces(TorrentBin, 0, MetadataSize)),
        is_private=etorrent_metainfo:is_private(Torrent)
    },
    %% GC
    {ok, InitState, hibernate}.


%% @private

handle_call(magnet_link, _, State=#state{info_hash=IntIH, torrent_name=Name,
            tracker_tiers=TrackerTiers}) ->
    URL = etorrent_magnet:build_url(IntIH, Name, lists:merge(TrackerTiers)),
    {reply, {ok, URL}, State};
handle_call({get_info, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        X=#file_info{} ->
            {reply, {ok, X}, State}
    end;

handle_call({position, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info{position=P} ->
            {reply, {ok, P}, State}
    end;

handle_call({size, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info{size=Size} ->
            {reply, {ok, Size}, State}
    end;

handle_call(chunk_size, _, State=#state{chunk_size=S}) ->
    {reply, {ok, S}, State};

handle_call(piece_size, _, State=#state{piece_size=S}) ->
    {reply, {ok, S}, State};

handle_call({piece_size, PieceNum}, _, State=#state{
        piece_size=PieceSize, total_size=TotalSize, piece_count=PieceCount}) ->
    Size = calc_piece_size(PieceNum, PieceSize, TotalSize, PieceCount),
    {reply, {ok, Size}, State};

handle_call(piece_count, _, State=#state{piece_count=C}) ->
    {reply, {ok, C}, State};

handle_call(is_private, _, State=#state{is_private=X}) ->
    {reply, {ok, X}, State};

handle_call({get_mask, FileID, PartStart, PartSize}, _, State) ->
    #state{static_file_info=Arr, total_size=TLen, piece_size=PLen} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info {position = FileStart} ->
            %% true = PartSize =< FileSize,

            %% Start from beginning of the torrent
            From = FileStart + PartStart,
            Mask = make_mask(From, PartSize, PLen, TLen),
            Set = etorrent_pieceset:from_bitstring(Mask),

            {reply, {ok, Set}, State}
    end;
    
handle_call({get_mask, FileID, IsGreedy}, _, State) ->
    #state{static_file_info=Arr,
           piece_size=PLen,
           total_size=TLen} = State,
    Mask = get_mask_int(FileID, Arr, PLen, TLen, IsGreedy),
    {reply, {ok, Mask}, State};

handle_call({long_file_name, FileIDs}, _, State) ->
    #state{static_file_info=Arr} = State,

    F = fun(FileID) -> 
            Rec = array:get(FileID, Arr), 
            Rec#file_info.name
       end,

    Reply = try 
        NameList = lists:map(F, FileIDs),
        NameBinary = list_to_binary(string:join(NameList, ", ")),
        {ok, NameBinary}
        catch error:_ ->
            lager:error("List of ids ~w caused an error.", 
                [FileIDs]),
            {error, badid}
        end,
            
    {reply, Reply, State};

handle_call({file_name, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
    undefined ->
       {reply, {error, badid}, State};
    #file_info {name = Name} ->
       {reply, {ok, Name}, State}
    end;

handle_call({minimize_filelist, FileIDs}, _, State) ->
    #state{static_file_info=Arr} = State,
    {reply, {ok, minimize_filelist_priv(FileIDs, Arr)}, State};

handle_call({tree_children, FileID}, _, State) ->
    #state{static_file_info=Arr} = State,
    case array:get(FileID, Arr) of
        undefined ->
            {reply, {error, badid}, State};
        #file_info {children = Ids} ->
            Children = [array:get(Id, Arr) || Id <- Ids],
            {reply, {ok, Children}, State}
    end;
handle_call({files, FileIDs}, _, State) ->
    #state{static_file_info=Arr} = State,
    Nodes = [array:get(Id, Arr) || Id <- FileIDs],
    {reply, {ok, Nodes}, State};
handle_call(metadata_size, _, State) ->
    #state{metadata_size=MetadataSize} = State,
    {reply, {ok, MetadataSize}, State};
handle_call({get_piece, PieceNum}, _, State=#state{metadata_pieces=Pieces})
        when PieceNum < tuple_size(Pieces) ->
    {reply, {ok, element(PieceNum+1, Pieces)}, State};
handle_call({get_piece, PieceNum}, _, State=#state{}) ->
    {reply, {ok, {bad_piece, PieceNum}}, State};

handle_call({mask_to_filelist, Mask}, _, State=#state{}) ->
    #state{static_file_info=Arr} = State,
    List = mask_to_filelist_int(Mask, Arr, true),
    {reply, {ok, List}, State};

handle_call({mask_to_size, Mask}, _, State=#state{}) ->
    #state{total_size=TLen, piece_size=PLen} = State,
    Size = mask_to_size(Mask, TLen, PLen),
    {reply, {ok, Size}, State}.


%% @private
handle_cast(Msg, State) ->
    lager:warning("Spurious handle cast: ~p", [Msg]),
    {noreply, State}.
    

%% @private
handle_info(Msg, State) ->
    lager:warning("Spurious handle info: ~p", [Msg]),
    {noreply, State}.

%% @private
terminate(_, _) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ----------------------------------------------------------------------



%% -\/-----------------FILE INFO API----------------------\/-
%% @private
collect_static_file_info(Torrent) ->
    PieceLength = etorrent_metainfo:get_piece_length(Torrent),
    FileLengths = etorrent_metainfo:file_path_len(Torrent),
    %% Rec1, Rec2, .. are lists of nodes.
    %% Calculate positions, create records. They are still not prepared.
    {TLen, Rec1} = flen_to_record(FileLengths, 0, []),
    %% Add directories as additional nodes.
    [#file_info{size=TLen2}|_] = Rec2 = add_directories(Rec1),
    assert_total_length(TLen, TLen2),

    Rec3 = init_ranges(Rec2),
    Rec4 = merge_duplicate_directories(Rec3),
    %% Fill `pieces' field.
    %% A mask is a set of pieces which contains the file.
    Rec5 = fill_pieces(Rec4, PieceLength, TLen),
    Rec6 = fill_distinct_pieces(Rec5, PieceLength, TLen),
    Rec7 = fill_short_name(Rec6),
    DirIds = [FileId || #file_info{id=FileId, children=[_|_]} <- Rec7],
    FileId2RecPL = [{FileId, Rec} || Rec=#file_info{id=FileId} <- Rec7],
    FileId2RecOD = orddict:from_list(FileId2RecPL),
    {array:from_orddict(FileId2RecOD), PieceLength, TLen, DirIds}.

%% @private
flen_to_record([{Name, FLen} | T], From, Acc) ->
    To = From + FLen,
    X = #file_info {
        type = file,
        name = Name,
        position = From,
        size = FLen
    },
    flen_to_record(T, To, [X|Acc]);

flen_to_record([], TotalLen, Acc) ->
    {TotalLen, lists:reverse(Acc)}.


%% @private
add_directories(Rec1) ->
    Idx = 1,
    {Rec2, Children, Idx1, []} = add_directories_(Rec1, Idx, 1, 0, [], "", [], []),
    [Last|_] = Rec2,
    Rec3 = lists:reverse(Rec2),

    #file_info {
        size = LastSize,
        position = LastPos
    } = Last,

    Root = #file_info {
        id = 0,
        level = 0,
        name = "",
        % total size
        size = (LastSize + LastPos),
        position = 0,
        children = Children,
        capacity = Idx1 - Idx
    },

    [Root|Rec3].


init_ranges(Recs) ->
    [X#file_info{byte_ranges=[{Pos, Size}]}
     || X=#file_info{position = Pos, size = Size} <- Recs].


merge_duplicate_directories(Rec1) ->
    Rec2 = lists:keysort(#file_info.name, Rec1),
    {Rec3, Rewritten} = merge_duplicate_directories_1(Rec2, [], []),
    Old2NewIdDict = dict:from_list(Rewritten),
    rewrite_records(Rec3, Old2NewIdDict).


rewrite_records(Recs, Old2NewIdDict) ->
    [X#file_info{
        parent_id = rewrite_id(ParentId, Old2NewIdDict),
        children = rewrite_ids(Children, Old2NewIdDict),
        parents = rewrite_ids(Parents, Old2NewIdDict)}
     || X=#file_info{
                parent_id = ParentId,
                children = Children,
                parents =Parents} <- Recs].


rewrite_ids(OldIds, Old2NewIdDict) ->
    lists:usort([rewrite_id(OldId, Old2NewIdDict) || OldId <- OldIds]).

rewrite_id(OldId, Old2NewIdDict) ->
    dict_get_value(OldId, Old2NewIdDict, OldId).

dict_get_value(Key, Dict, DefValue) ->
    case dict:find(Key, Dict) of
        {ok, Value} -> Value;
        error -> DefValue
    end.

merge_duplicate_directories_1([H1=#file_info{name = N},
                               H2=#file_info{name = N}|T], Recs, Retwritten) ->
    #file_info{
        id = Id1,
        parent_id = ParentId,
        level = Lvl,
        size = Size1,
        position = Pos1,
        parents = Parents,
        children = Children1,
        capacity = Capacity1,
        byte_ranges = Ranges1
    } = H1,
    #file_info{
        id = Id2,
        parent_id = ParentId,
        level = Lvl,
        size = Size2,
        parents = Parents,
        children = Children2,
        capacity = Capacity2,
        byte_ranges = Ranges2
    } = H2,
    H = #file_info{name = N, 
        id = Id1,
        parent_id = ParentId,
        level = Lvl,
        size = Size1 + Size2,
        position = Pos1,
        parents = Parents,
        children = Children1 ++ Children2,
        capacity = Capacity1 + Capacity2,
        byte_ranges = Ranges1 ++ Ranges2
    },
    merge_duplicate_directories_1([H|T], Recs, [{Id2, Id1}|Retwritten]);
merge_duplicate_directories_1([H|T], Recs, Rewritten) ->
    merge_duplicate_directories_1(T, [H|Recs], Rewritten);
merge_duplicate_directories_1([], Recs, Rewritten) ->
    {lists:reverse(Recs), Rewritten}.


%% "test/t1.txt"
%% "t2.txt"
%% "dir1/dir/x.x"
%% ==>
%% "."
%% "test"
%% "test/t1.txt"
%% "t2.txt"
%% "dir1"
%% "dir1/dir"
%% "dir1/dir/x.x"

%% @private
dirname_(Name) ->
    case filename:dirname(Name) of
        "." -> "";
        Dir -> Dir
    end.

%% @private
first_token_(Path) ->
    case filename:split(Path) of
    ["/", Token | _] -> Token;
    [Token | _] -> Token
    end.

%% @private
file_join_(L, R) ->
    case filename:join(L, R) of
        "/" ++ X -> X;
        X -> X
    end.

file_prefix_(S1, S2) ->
    lists:prefix(filename:split(S1), filename:split(S2)).


%% @private
add_directories_([], Idx, _ParentIdx, _Lvl, _Path, _Cur, Children, Acc) ->
    {Acc, lists:reverse(Children), Idx, []};

add_directories_([H|T], Idx, ParentIdx, Lvl, Path, Cur, Children, Acc) ->
    #file_info{ name = Name, position = CurPos } = H,
    Dir = dirname_(Name),
    Action = case Dir of
            Cur -> 'equal';
            _   ->
                case file_prefix_(Cur, Dir) of
                    true -> 'prefix';
                    false -> 'other'
                end
        end,

    case Action of
        %% file is in the same directory
        'equal' ->
            H1 = H#file_info{
                    id = Idx,
                    level = Lvl,
                    parent_id = ParentIdx,
                    parents = Path},
            add_directories_(T, Idx+1, ParentIdx, Lvl, Path, Dir, [Idx|Children], [H1|Acc]);

        %% file is in the child directory
        'prefix' ->
            Sub = Dir -- Cur,
            Part = first_token_(Sub),
            NextDir = file_join_(Cur, Part),

            {SubAcc, SubCh, Idx1, SubT} 
                = add_directories_([H|T], Idx+1, Idx, Lvl+1, [Idx|Path], NextDir, [], []),
            [#file_info{ position = LastPos, size = LastSize }|_] = SubAcc,

            DirRec = #file_info {
                id = Idx,
                level = Lvl,
                parent_id = ParentIdx,
                parents = Path,
                name = NextDir,
                size = (LastPos + LastSize - CurPos),
                position = CurPos,
                children = SubCh,
                capacity = Idx1 - Idx
            },
            NewAcc = SubAcc ++ [DirRec|Acc],
            add_directories_(SubT, Idx1, ParentIdx, Lvl, Path, Cur, [Idx|Children], NewAcc);
        
        %% file is in an other directory
        'other' ->
            {Acc, lists:reverse(Children), Idx, [H|T]}
    end.


%% @private
fill_pieces(RecList, PLen, TLen) ->
    F = fun(#file_info{byte_ranges = Ranges} = Rec) ->
            %% Be greedy.
            Sets = [etorrent_pieceset:from_bitstring(
                        make_mask(From, Size, PLen, TLen, true))
                    || {From, Size} <- Ranges],
            Set = etorrent_pieceset:union(Sets),
            Rec#file_info{pieces = Set}
        end,
        
    lists:map(F, RecList).    

fill_distinct_pieces(RecList, PLen, TLen) ->
    F = fun(#file_info{byte_ranges = Ranges} = Rec) ->
            %% Don't be greedy.
            Sets = [etorrent_pieceset:from_bitstring(
                        make_mask(From, Size, PLen, TLen, false))
                    || {From, Size} <- Ranges],
            Set = etorrent_pieceset:union(Sets),
            Rec#file_info{distinct_pieces = Set}
        end,
        
    lists:map(F, RecList).    

fill_short_name(Recs) ->
    [X#file_info{short_name = list_to_binary(filename:basename(Name))}
     || X=#file_info{name = Name} <- Recs].


make_mask(From, Size, PLen, TLen) ->
    make_mask(From, Size, PLen, TLen, true).

-spec make_mask(From, Size, PLen, TLen, IsGreedy) -> Mask when
    From :: non_neg_integer(),
    Size :: non_neg_integer(),
    PLen :: non_neg_integer(),
    TLen :: non_neg_integer(),
    IsGreedy :: boolean(),
    Mask :: pieceset().

%% @private
make_mask(From, Size, PLen, TLen, IsGreedy)
    when PLen =< TLen, Size =< TLen, From >= 0, PLen > 0 ->
    %% __Bytes__: 1 <= From <= To <= TLen
    %%
    %% Calculate how many __pieces__ before, in and after the file.
    %% Be greedy: when the file ends inside a piece, then put this piece
    %% both into this file and into the next file.
    %% [0..X1 ) [X1..X2] (X2..MaxPieces]
    %% [before) [  in  ] (    after    ]
    PTotal = byte_to_piece_count(TLen, PLen),

    %% indexing from 0
    PFrom  = byte_to_piece_index(From, PLen, IsGreedy),

    PBefore = PFrom,
    PIn     = byte_to_piece_count_beetween(From, Size, PLen, TLen, IsGreedy),
    PAfter  = PTotal - PIn - PBefore,
    assert_positive(PBefore),
    assert_positive(PIn),
    assert_positive(PAfter),
    <<0:PBefore, -1:PIn, 0:PAfter>>.


minimize_filelist_priv(FileIDs, Arr) ->
    case lists:usort(FileIDs) of
        [] -> []; %% empty
        [X] -> [X]; %% trivial
        [0|_] -> [0]; %% all files
        FileIDs1 -> minimize_filelist_priv_1(FileIDs1, Arr)
    end.

minimize_filelist_priv_1(FileIDs, Arr) ->
    FileSet = sets:from_list(FileIDs),
    RecList = [ array:get(FileID, Arr) || FileID <- FileIDs ],
    %% RecList without double-inclusion
    %% (i.e. it contains parents, but not their children).
    RecList1 = [X || X=#file_info{parents = Parents} <- RecList,
                %% Filter, if at least one of the parents is listed here too.
                not lists:any(
                    fun(ParentId) -> sets:is_element(ParentId, FileSet) end,
                    Parents)],

    MaxLvl = lists:foldl(fun(#file_info{level=Lvl}, Max) -> max(Lvl, Max) end,
                         0, RecList1),

    %% `[{0, []}, {1, [#file_info{},...]}, {2, [#file_info{}]}]'
    RecByLvl = [{Lvl, [Rec || Rec=#file_info{level=RecLvl} <- RecList1,
                              Lvl =:= RecLvl]}
                || Lvl <- lists:seq(0, MaxLvl)],

    {MergedAcc, SameAcc} = minimize_filelist_priv_2(RecByLvl, Arr, [], []),
    FileIDs2 = [FileID || #file_info{id = FileID} <- MergedAcc ++ SameAcc],
    lists:sort(FileIDs2).

%% This function is not tail recursive.
%% First element of `RecByLvl' is an element with lowerest level.
minimize_filelist_priv_2([], _Arr, MergedAcc, SameAcc) ->
    {MergedAcc, SameAcc};
minimize_filelist_priv_2([{_Lvl, RecList}|RecByLvl], Arr, MergedAcc, SameAcc) ->
    %% Pass RecList as MergedAcc on the next level.
    {MergedAcc1, SameAcc1} = minimize_filelist_priv_2(RecByLvl, Arr,
                                                      RecList, SameAcc),
    RecList1 = lists:usort(MergedAcc1),
    ParentIds = [ ParentId || #file_info{parent_id=ParentId} <- RecList1],
    ParentId2Children = [{ParentId,
                          filter_by_parent_id(RecList1, ParentId),
                          get_children_ids(ParentId, Arr)}
                         || ParentId <- ParentIds, ParentId =/= undefined],
    %% If child id sets are equal, than these children are consumed by its parent.
    MergedIdList = [ParentId || {ParentId, X, X} <- ParentId2Children],
    MergedIdSet = sets:from_list(MergedIdList),
    Same = [Rec || Rec=#file_info{parent_id=ParentId} <- RecList1,
                   not sets:is_element(ParentId, MergedIdSet)],
    Merged = [array:get(ParentId, Arr) || ParentId <- MergedIdList],
    {Merged ++ MergedAcc, Same ++ SameAcc1}.


get_children_ids(Id, Arr) ->
    case array:get(Id, Arr) of
        #file_info{children = Children} -> Children;
        BadRec -> error({not_a_record, Id, BadRec})
    end.

filter_by_parent_id(RecList, ParentId) ->
    [Id || #file_info{id=Id, parent_id=ParentId_1} <- RecList,
           ParentId =:= ParentId_1].

%% -/\-----------------FILE INFO API----------------------/\-

-ifdef(TEST).

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


%% Not last.
metadata_pieces(TorrentBin, From, MetadataSize)
    when MetadataSize > ?METADATA_BLOCK_BYTE_SIZE ->
    [binary:part(TorrentBin, {From,?METADATA_BLOCK_BYTE_SIZE})
    |metadata_pieces(TorrentBin,
                     From+?METADATA_BLOCK_BYTE_SIZE, 
                     MetadataSize-?METADATA_BLOCK_BYTE_SIZE)];

%% Last.
metadata_pieces(TorrentBin, From, MetadataSize) ->
    [binary:part(TorrentBin, {From,MetadataSize})].


assert_total_length(TLen, TLen) ->
    ok;
assert_total_length(TLen, TLen2) ->
    error({assert_total_length, TLen, TLen2}).


assert_positive(X) when X >= 0 ->
    ok;
assert_positive(X) ->
    error({assert_positive, X}).


byte_to_piece_count(TLen, PLen) ->
    (TLen div PLen) + case TLen rem PLen of 0 -> 0; _ -> 1 end.

byte_to_piece_index(Pos, PLen, true) ->
    Pos div PLen;
byte_to_piece_index(Pos, PLen, false) ->
    case Pos rem PLen of
        %% Bytes:  |0123|4567|89AB|
        %% Pieces: |0   |1   |2   |
        %% Set:    |----|xxxx|xxx-|
        %% Index: 1
        0 -> Pos div PLen;
        %% Bytes:  |0123|4567|89AB|
        %% Pieces: |0   |1   |2   |
        %% Set:    |---x|xxxx|xxx-|
        %% Index: 1
        %% Rem: 3
        _ -> (Pos div PLen) + 1
    end.


%% Bytes:  |0123|4567|89AB|
%% Pieces: |0   |1   |2   |
%% Set:    |---x|xxxx|xxx-|
%% From:   3
%% Size:   8
%% PLen:   4
%% Left:   1
%% Right:  3
%% Mid:    4
%% PLeft:  1
%% PRight: 1
%% PMid:   1
byte_to_piece_count_beetween(From, Size, PLen, _TLen, true) ->
    %% Greedy.
    To     = From + Size,
    Left   = case From rem PLen of 0 -> 0; X -> PLen - X end,
    Right  = To rem PLen,
    Mid    = Size - Left - Right,
    PLeft  = case Left  of 0 -> 0; _ -> 1 end,
    PRight = case Right of 0 -> 0; _ -> 1 end,
    PMid   = Mid div PLen,
    %% assert
    0      = Mid rem PLen,
    PMid + PLeft + PRight;
%% Bytes:  |0123|4567|89AB|
%% Pieces: |0   |1   |2   |
%% Set:    |---x|xxxx|xxx-|
%% From:   3
%% Size:   8
%% PLen:   4
%% Result: 1
byte_to_piece_count_beetween(From, Size, PLen, TLen, false) 
    when Size < PLen -> 0 + check_last_piece(From, Size, PLen, TLen);
    %% heuristic
byte_to_piece_count_beetween(From, Size, PLen, TLen, false) ->
    %% Ungreedy.
    To     = From + Size,
    Left   = case From rem PLen of 0 -> 0; X -> PLen - X end,
    Right  = To rem PLen,
    Mid    = Size - Left - Right,
    (Mid div PLen) + check_last_piece(From, Size, PLen, TLen).

%% If last piece has non-standard size and it fully included, return 1.
check_last_piece(From, Size, PLen, TLen) ->
    LastPieceSize = TLen rem PLen,
    %% If LastPieceSize =:= 0, then the last piece has a standard length.
    if LastPieceSize =/= 0, LastPieceSize =< Size, From + Size =:= TLen -> 1;
       true -> 0
    end.
    
    
    

-ifdef(TEST).
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

%% The last piece has the same size as all others.
mask_to_size(Mask, TLen, PLen) when TLen rem PLen =:= 0 ->
    etorrent_pieceset:size(Mask) * PLen;
mask_to_size(Mask, TLen, PLen) ->
    case etorrent_pieceset:size(Mask) of
        0 -> 0;
        PCount ->
            %% Pieces:
            %% |1234|567-|
            %% TLen = 7, PLen = 4, LastPieceId = 1
            LastPieceId    = TLen div PLen,
            LastPieceSize  = TLen rem PLen,
            IsLastPieceSet = etorrent_pieceset:is_member(LastPieceId, Mask),
            if IsLastPieceSet -> ((PCount - 1) * PLen) + LastPieceSize;
                         %% All PCount pieces have the same size.
                         true -> PCount * PLen 
            end
    end.


-ifdef(TEST).
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


%% Internal.
-spec mask_to_filelist_int(Mask, Arr, IsGreedy) -> [FileID] when
    Mask :: pieceset(),
    Arr :: term(),
    IsGreedy :: boolean(),
    FileID :: file_id().
mask_to_filelist_int(Mask, Arr, true) ->
    Root = array:get(?ROOT_FILE_ID, Arr),
    case Root of
        %% Everything is unwanted.
        #file_info{pieces=Mask} ->
            [0];
        #file_info{children=SubFileIds} ->
            mask_to_filelist_rec(SubFileIds, Mask, Arr, #file_info.pieces)
    end;
mask_to_filelist_int(Mask, Arr, false) ->
    Root = array:get(?ROOT_FILE_ID, Arr),
    case Root of
        %% Everything is unwanted.
        #file_info{distinct_pieces=Mask} ->
            [0];
        #file_info{children=SubFileIds} ->
            mask_to_filelist_rec(SubFileIds, Mask, Arr,
                                 #file_info.distinct_pieces)
    end.

%% Matching all files starting from Root recursively.
mask_to_filelist_rec([FileId|FileIds], Mask, Arr, PieceField) ->
    File = #file_info{children=SubFileIds} = array:get(FileId, Arr),
    FileMask = element(PieceField, File),
    Diff = etorrent_pieceset:difference(FileMask, Mask),
    case {etorrent_pieceset:is_empty(FileMask),
          etorrent_pieceset:is_empty(Diff)} of
        {true, true} ->
            mask_to_filelist_rec_tiny_file(File, Mask) ++
            mask_to_filelist_rec(FileIds, Mask, Arr, PieceField);
        {false, true} ->
            %% The whole file is matched.
            [FileId|mask_to_filelist_rec(FileIds, Mask, Arr, PieceField)];
        {false, false} ->
            %% Check childrens.
            mask_to_filelist_rec(SubFileIds, Mask, Arr, PieceField) ++
            mask_to_filelist_rec(FileIds, Mask, Arr, PieceField)
    end;
mask_to_filelist_rec([], _Mask, _Arr, _PieceField) ->
    [].

%% When IsGreedy = false, small files can be skipped.
%% This function is for this case.
mask_to_filelist_rec_tiny_file(#file_info{id=Id, pieces=FileMask}, Mask) ->
    Diff = etorrent_pieceset:difference(FileMask, Mask),
    [Id || etorrent_pieceset:is_empty(Diff)].


-ifdef(TEST).

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





get_mask_int(FileID, Arr, _PLen, _TLen, true)
    when is_integer(FileID) ->
    get_greedy_mask(FileID, Arr);
get_mask_int([_|_]=FileIDs, Arr, _PLen, _TLen, true) ->
    %% Do map
    Masks = [get_greedy_mask(FileID, Arr) || FileID <- FileIDs],
    %% Do reduce
    etorrent_pieceset:union(Masks);

get_mask_int([], _Arr, PLen, TLen, _IsGreedy) ->
    PieceCount = byte_to_piece_count(TLen, PLen),
    etorrent_pieceset:empty(PieceCount);

get_mask_int(FileID, Arr, _PLen, _TLen, false) when is_integer(FileID) ->
    get_distinct_mask(FileID, Arr);

get_mask_int([_|_]=FileIDs, Arr, PLen, TLen, false) ->
    %% TESTME
    %% It does not work, when we pass directory and its descenders.
    Files = [array:get(FileID, Arr) || FileID <- lists:usort(FileIDs)],
    ByteRanges = recs_to_byte_ranges(Files),
    ByteRanges2 = collapse_ranges(ByteRanges),
    Field = byte_ranges_to_mask(ByteRanges2, 0, PLen, TLen, false, <<>>),
    etorrent_pieceset:from_bitstring(Field).


get_greedy_mask(FileID, Arr) ->
    #file_info{pieces=Mask} = array:get(FileID, Arr),
    Mask.

get_distinct_mask(FileID, Arr) ->
    #file_info{distinct_pieces=Mask} = array:get(FileID, Arr),
    Mask.

recs_to_byte_ranges(Files) ->
    [Range || #file_info{byte_ranges = Ranges} <- Files, Range <- Ranges].

%% If one file ends in the same piece, as the next starts, than this
%% piece must be included.
%% TODO: This function can minimize ranges too, for example:
%%  [{0,6734117},
%%   {0,186178},
%%   {186178,595460},
%%   {781638,103642},
%%   {885280,358619},
%%   {1243899,642669},
%%   {1886568,830769}]
%%  [{55,6734117},
%%   {0,186178},
%%   {186178,595460},
%%   {781638,103642},
%%   {885280,358619},
%%   {1243899,642669},
%%   {1886568,830769}]
collapse_ranges([{F1,S1},{F2,S2}|Ranges])
    when F1+S2 =:= F2 ->
    %% Collapse
    collapse_ranges([{F1,S1+S2}|Ranges]);
collapse_ranges([Range|Ranges]) ->
    [Range|collapse_ranges(Ranges)];
collapse_ranges([]) ->
    [].


byte_ranges_to_mask([{From, Size}|Ranges], FromPiece, PLen, TLen, IsGreedy, Bin)
    when PLen =< TLen, Size =< TLen, From >= 0, PLen > 0, FromPiece >= 0 ->
    %% indexing from 0
    PFrom  = byte_to_piece_index(From, PLen, IsGreedy),
    PBefore = PFrom - FromPiece,
    PIn     = byte_to_piece_count_beetween(From, Size, PLen, TLen, IsGreedy),
    assert_positive(PBefore),
    assert_positive(PIn),
    FromPiece2 = PFrom + PIn,
    Bin2 = <<Bin/binary, 0:PBefore, -1:PIn>>,
    byte_ranges_to_mask(Ranges, FromPiece2, PLen, TLen, IsGreedy, Bin2);
byte_ranges_to_mask([], FromPiece, PLen, TLen, _IsGreedy, Bin) ->
    PTotal = byte_to_piece_count(TLen, PLen),
    PAfter = PTotal - FromPiece,
    <<Bin/binary, 0:PAfter>>.


-ifdef(TEST).

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


calc_piece_size(PieceNum, PieceSize, TotalSize, PieceCount)
        when (PieceNum + 1) =:= PieceCount ->
    %% Last piece
    case TotalSize rem PieceSize of
        0 -> PieceSize;
        Size -> Size
    end;
calc_piece_size(PieceNum, PieceSize, _, PieceCount)
        when PieceNum < PieceCount, PieceNum >= 0 ->
    %% Common size
    PieceSize.

-ifdef(TEST).

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

%% For small X and Y.
compare_floats(X, Y) ->
    abs(X - Y) < 0.0001.


pl_fetch_value(K, PL) ->
    case proplists:get_value(K, PL) of
        undefined -> error({bad_key, K, PL});
        V -> V
    end.


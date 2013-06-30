-module(etorrent_ext).
-export([new/2,
         extension_list/1,
         handle_handshake_respond/2,
         decode_msg/3,
         encode_msg/3,
         is_locally_supported/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type ext_id() :: 1 .. 255.
-type ext_name() :: atom().
-type ext_mod_name() :: atom().
-type ext_bname() :: binary().
-type bcode() :: etorrent_types:bcode().
-type option() :: private.

%% Local id => name as atom
%% Name as atom => remote id

-record(exts, {
        local_id2name      :: tuple(ext_name()),
        local_id2mod_name  :: tuple(ext_name()),
        bnames :: ordset:ordset(ext_bname()),
        mod_names :: ordset:ordset(ext_mod_name()),
        supported_name2remote_id_and_mod_name :: dict(),
        all_bname2remote_id = orddict:new() :: orddict:orddict(),
        m :: list({ext_bname(), ext_id()})
}).
-type ext_list() :: #exts{}.

is_public_only(ut_metadata) -> true;
is_public_only(ut_pex)      -> true;
is_public_only(_)           -> false.

% ======================================================================

-spec new([ext_name()], [option()]) -> #exts{}.
new(LocallySupportedNames, Options) ->
    IsPrivate = proplists:get_value(private, Options, false),
    %% Disable public-only extensions, if it is a private torrent.
    Names = 
        if IsPrivate -> [X || X <- LocallySupportedNames, not is_public_only(X)];
        true -> LocallySupportedNames
    end,

    Bnames = [atom_to_binary(NameAtom, utf8) || NameAtom <- Names],
    SortedBNames = lists:usort(Bnames),
    ModNames = gen_mod_list(SortedBNames),
    #exts{local_id2name=list_to_tuple(Names),
          bnames=SortedBNames,
          mod_names=ModNames,
          local_id2mod_name=list_to_tuple(ModNames),
          m = enumerate(Bnames, 1)
         }.

-spec handle_handshake_respond(RespondMsg::bcode(), Exts::ext_list()) -> ext_list().
handle_handshake_respond(RespondMsg, Exts=#exts{
        bnames=Bnames, mod_names=ModNames, all_bname2remote_id = RemExtBin2Id1}) ->
    case etorrent_bcoding:get_value(<<"m">>, RespondMsg) of
        undefined -> Exts;
        {} -> Exts;
        %% Add them.
        [_|_]=RemExtBin2Id2 ->
            RemExtBin2Id3 = lists:keysort(1, RemExtBin2Id2),
            RemExtBin2Id4 = update_ord_dict(RemExtBin2Id3, RemExtBin2Id1),
            Supported = filter_supported(RemExtBin2Id4, Bnames, ModNames),
            SupportedDict = dict:from_list(Supported),
            Exts#exts{supported_name2remote_id_and_mod_name = SupportedDict,
                      all_bname2remote_id = RemExtBin2Id4}
    end.


%% Generate <<"m">> block of the extension-handshake.
extension_list(#exts{m=M}) ->
    M.


is_locally_supported(ExtName, #exts{bnames=SortedBNames}) when is_atom(ExtName) ->
    ExtNameBin = atom_to_binary(ExtName, utf8),
    ordsets:is_element(ExtNameBin, SortedBNames).


decode_msg(LocalExtId, Msg, #exts{local_id2mod_name = Id2Mod})
    when is_integer(LocalExtId), is_binary(Msg), LocalExtId > 0 ->
    if 
    LocalExtId > tuple_size(Id2Mod) ->
        lager:error("Not supported extension with id = ~p.", [LocalExtId]),
        {error, not_supported_ext};
    true ->
        Mod = element(LocalExtId, Id2Mod),
        {ok, Mod:decode_msg(Msg)}
    end.


encode_msg(ExtName, Msg, #exts{supported_name2remote_id_and_mod_name = Name2IdMod})
    when is_atom(ExtName) ->
    case dict:find(ExtName, Name2IdMod) of
        {ok, {RemId, Mod}} ->
            {ok, {extended, RemId, Mod:encode_msg(Msg)}};
        error ->
            {error, not_supported_ext}
    end.

% ======================================================================

%% Skip all locally unsupported extensions.
-spec filter_supported([{BName, Id}], [BName], [MName]) -> [{Name,Id}] when
      BName :: ext_bname(),
      MName :: ext_mod_name(),
      Name :: ext_name(),
      Id :: ext_id().
filter_supported([{Name, Id}|Xs], [Name|Bnames], [MName|Mnames]) -> 
    [{binary_to_existing_atom(Name, utf8),{Id,MName}}
     |filter_supported(Xs, Bnames,Mnames)];
%% Remote node does not know the extension.
filter_supported([{RName, _Id}|_]=Xs, [LName|Bnames], [_|Mnames]) 
    when RName > LName ->
    lager:debug("Skip local extension: ~p", [LName]),
    filter_supported(Xs, Bnames, Mnames);
%% Local node does not know the extension.
filter_supported([{RName, _Id}|Xs], Bnames, Mnames) ->
    lager:debug("Skip remote extension: ~p", [RName]),
    filter_supported(Xs, Bnames, Mnames);
filter_supported(Xs, [], []) ->
    [lager:debug("Skip remote extension: ~p", [RName])
     || {RName, _Id} <- Xs],
    [];
filter_supported([], Xs, _) ->
    [lager:debug("Skip local extension: ~p", [LName])
     || LName <- Xs],
    [].


-ifdef(TEST).
filter_supported_test_() ->
    [?_assertEqual(filter_supported([{<<"x">>,1}, {<<"y">>,2}, {<<"z">>,3}],
                                    [<<"a">>,<<"x">>,<<"y">>],
                                    [xx,yy,zz]),
    ,?_assertEqual(filter_supported([],
                                    [<<"a">>],
                                    [xx]),
                   [])
    ].
-endif.




%% Arguments are sorted by the 1st field.
%% Too extensions with the same name, it is strange. Skip the first.
update_ord_dict([{Name,_}, [{Name,_}|_]=News], Olds) ->
    update_ord_dict(News, Olds);
%% Disable this extension.
update_ord_dict([{Name,0}|News], [{Name,_}|Olds]) ->
    update_ord_dict(News, Olds);
%% Set a new id.
update_ord_dict([{Name,Id}|News], [{Name,_}|Olds]) ->
    [{Name,Id}|update_ord_dict(News, Olds)];
%% Add a new element.
%% Element is in `Olds' but not in `News'.
update_ord_dict([{NewName,_}|_]=News, [{OldName,_}=Old|Olds])
    when NewName > OldName ->
    [Old|update_ord_dict(News, Olds)];
%% Skip unsettiong command. Strange.
update_ord_dict([{_,0}|News], [_|_]=Olds) ->
    update_ord_dict(News, Olds);
%% Keep this extension as is.
%% Element is in `News' but not in `Olds'.
update_ord_dict([New|News], [_|_]=Olds) ->
    [New|update_ord_dict(News, Olds)];
update_ord_dict([_|_]=News, []) ->
    [{Name,Id} || {Name,Id} <- News, Id < 256, Id > 0];
update_ord_dict([], [_|_]=Olds) ->
    Olds.


-ifdef(TEST).
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

gen_mod_list(Bnames) ->
    [binary_to_atom(<<"etorrent_ext_", Bname/binary>>, utf8) || Bname <- Bnames].


enumerate([H|T], N) ->
    [{H,N}|enumerate(T, N+1)];
enumerate([], _N) ->
    [].

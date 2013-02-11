-module(etorrent_ext_ut_metadata).
-export([decode_msg/1,
         encode_msg/1]).

decode_msg(Msg) when is_binary(Msg) ->
    {Header, Piece} = etorrent_bcoding2:decode(Msg),
    V = fun(X) -> etorrent_bcoding:get_value(X, Header) end,
    case V(<<"msg_type">>) of
        0 -> {metadata_request, V(<<"piece">>)};
        1 -> {metadata_data,    V(<<"piece">>), V(<<"total_size">>), Piece};
        2 -> {metadata_reject,  V(<<"piece">>)}
    end.


encode_msg({metadata_request, PieceNum}) ->
    Data = [{<<"msg_type">>, 0}, {<<"piece">>, PieceNum}],
    etorrent_bcoding:encode(Data);
encode_msg({metadata_reject, PieceNum}) ->
    Data = [{<<"msg_type">>, 2}, {<<"piece">>, PieceNum}],
    etorrent_bcoding:encode(Data);
encode_msg({metadata_data, PieceNum, TotalSize, Piece})
    when is_integer(Piece) ->
    Data = [{<<"msg_type">>, 1},
            {<<"piece">>, PieceNum},
            {<<"total_size">>, TotalSize}],
    Header = etorrent_bcoding:encode(Data),
    <<Header/binary, Piece/binary>>.

%% For simplicity, the test picks a smaller range in which to
%% place nodes. This not only makes it easier to tets for corner cases,
%% it also makes it easier to figure out what happens in the routing table.
-define(BITS, 7).
-define(ID_MIN, 0).
-define(ID_MAX, 1 bsl ?BITS).

%% Maximal size of a range is defined exactly as in the SUT
-define(MAX_RANGE_SZ, 8).


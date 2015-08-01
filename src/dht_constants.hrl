%
% Defines the maximal bucket size
-define(MAX_RANGE_SZ, 8).
-define(MIN_ID, 0).
-define(MAX_ID, 1 bsl 256).

%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
-define(RANGE_TIMEOUT, 15 * 60 * 1000).
-define(NODE_TIMEOUT, 15 * 60 * 1000).

%
% For how long will you believe in a stored value?
-define(REFRESH_TIME, 45 * 60 * 1000).
-define(STORE_TIME, 60 * 60 * 1000).

%
% How many nodes to store at when we find nodes
-define(STORE_COUNT, 8).

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


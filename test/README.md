# TODO list of mistakes

* The network stack needs to be combed for when it tells the state engine it got request_success.
* Make dht_state/request_* into casts
* Think a lot about when to tell the `dht_state` about when things should be touched. The current setup ignores those things completely. It can probably be generally defined if we think about it.
* Reset empty ranges correctly
* The notion of inserting a node, and touching a node is really the same thing. You can handle them as one if you think a bit about it I hope.

# Tests and specification of the DHT

This directory contains tests for the DHT system. The tests are captured in the module `dht_SUITE` and running tests will run this suite. The way to run these is from the top-level:

	rebar3 ct

Every test in this project are QuickCheck tests and requires Erlang QuickCheck.

This file contains most of the prose written in order to understand what the specification of the system is. Each module contains further low-level documentation. Do *NOT* rely too much on the text in this file, but refer to the actual specification when in doubt. It is precise, whereas this text is not. For instance, the tests can make the discrimination between `L < 8` and `L ≤8` which is harder to manage with text.

# Test strategy

To make sure the code works as expected, we split the tests into QuickCheck components are start by verifying each component on its own. Once we have individual verfication, we cluster the components using the Erlang QuickCheck `eqc_cluster` feature. In turn, this allows us to handle the full specification from simpler parts.

For each Erlang module, we define a *component* which has a *mocking* *specification* for every call it makes to the outside. This allows us to isolate each module on its own and test it without involving the specification of other modules. We also often overspecify what the module accepts to make sure it works even if the underlying modules change a bit.

Once we have all components, we assemble them into a cluster. Now, the mocking specifications are replaced with actual models. In turn, a callout to a mock can now be verified by the preconditions of the underlying model. This ensures the composition of components are safe.

# Test Model

In the real system, the ID-space used is 160 bit (SHA-1) or 256 bit (SHA-256). In our test case, in order to hit limits faster, we pick an ID-space of 7 bit (128 positions). This allows us to find corner cases much faster and it is also more likely we hit counterexamples earlier.

# Specification

In order to make sure the code performs as defined in the DHT BitTorrent BEP 0005 spec, this code defines a model of the specification which is executed against the DHT code. Using QuickCheck, random test cases are generated from the specification and are then used as tests. Usually, 100 randomly generated test cases are enough to uncover errors in the system, but before releases we run test cases for much larger counts: hundreds of thousands to millions.

There are many modules, each covering part of what the DHT is doing.

The DHT system roughly contains three parts:

* The Storage, storing values which are being advertised into the DHT
* The Network stack, handling all network communication, protocol handling and request/reply proxying.
* The State system, tracking the routing table of the DHT known to the particular node.

## Metric

The Kademlia DHT relies on a “distance function”, which is `XOR`. The claim is that this is a metric, which has well-defined mathematical properties. We verify this to be the case for the domain on which the function is defined, while in the original paper, it is just mentioned in passing. By defining we require a metric, we can later change the metric to another one.

## Randomness

The specification mentions the need for picking random values. In a QuickCheck test we don't want picked values to be random, as we want to know what value we picked. Thus we provide a model for randomness and mock it through `dht_rand`.

## Time

Time is often a problem in models because the system runs on a different time scale when it is tested. We solve this by requiring all time calls to factor through the module `dht_time`, which we then promptly mock. This means the models can contain their own notion of time and when the SUT requests the time, we can control it. The same is true for setting and cancelling timers.

*NOTE:* We use a time resolution of `milli_seconds` for the models and we assume this is the “native” time resolution. This makes it easier to handle rather than the nano-second default which is used on the system by default.

All time in the system is `monotonic_time()`. This makes all of the code time-warp-safe.

## Routing table

Routing ID's are positive integers. They have a digital bit-representation as lists of bits. These bits form a binary tree structure. The routing table is such a “path” in such a binary tree, considering a prefix of the bit-string. The rules are:

* Leafs have at most 8 nodes
* If inserting a new node into a leaf of size 8, there are two cases:
	* Our own ID has a common prefix `P` with the leaf: Partition the leaf into nodes with prefix follow by a `0` bit: `P0` and prefix followed by a `1` bit: `P1`. These become the new leafs. One of these leafs contain our own ID, whereas the other does not. This ensure only one subtree will split later on.
	* Our own ID is not a common prefix with the leaf: reject the insertion.
	
In turn, the routing table is a “spine” in the tree only where the path mimicks our own ID. In turn, the routing table stores more elements close to ourselves rather than far away from ourselves.

When there are 3 bits left in the suffix, the tree will not expand further since you can at most have 8 nodes in a leaf. This MUST hold, but it only holds if equality is on the NodeID. Example: In a 160 bit ID space, if you have a suffix of 157 bits in common with our own ID, there can at most be 3 bits which can vary. Our own ID is one of those, so there are 7 nodes left. They will fill the leaf, but it is impossible to insert more nodes into the table.

### Modeling the routing table

We use a simple `map({Lo, Hi}, [Node])` as the model of the routing table in our component. `Lo` and `Hi` are the bounds on the range: all elements `X` in the range has an id such that `Lo ≤ id(X) < Hi`. Most operations are straightforward to define since we can just walk all of the range and filter it by predicate functions which pick the wanted elements.

The `closest_to` call looks hard to implement, but it's formal specification is straightforward: sort all nodes based on the distance to the desired ID, and pick the first K of those nodes. If we canonicalize the output by sorting it, we
obtain a correct specification.

### Node reachability

Nodes in the routing table are either "reachable" or not. Nodes which are "reachable" are nodes which are not thought to be behind a firewall, which means they are possible to contact at any time.

Some commands, touching nodes, inserting nodes into the node table and so on, exists in two variants, one where we know about reachability and one where we don't. Consider a query, originating from us to a peer, and that peer responding. This gives a valid reachability notion for that node. On the other hand, we we receive a query from a peer, it is not by default reachable, so we update the node with a notion of a non-reachable state.

## Routing table metadata

The routing table is wrapped into a module tracking “meta-data” which is timer information associated with each entry in the routing table. There are two rules:

* For each node in the routing table, we know the timing state of that node
* For each leaf in the routing table, we know it's timing state

This is verified to be the case, by mandating each insertion also provides a corresponding meta-data entry.

A node can be in one of three possible states:

* Good—we have succesfully communicated with the node recently.
* Questionable—we have not communicated with the node recently, and we don't know its current state.
* Bad—Communication with the node has failed repeatedly.

Of course, “recently” and “repeatedly” has to be defined. We define the timeout limit to be 15 minutes and we define that nodes which have failed MORE THAN 1 time are bad nodes. These numbers could be changed, but they are not well-defined.

We don't track the Node state with a timer. Rather, we note the last succesful point of communication. This means a simple calculation defines when a node becomes questionable, and thus needs a refresh.

The reason we do it this way, is that all refreshes of nodes are event-driven: the node is refreshed whenever it communicates or when we want to use that node. So if we know the point-in-time for last communication, we can determine its internal state, be it `good`, `questionable`, or `bad`.

The meta-data tracks nodes with the following map:

	Node => #{ last_activity => time_point(), timeout_count => non_neg_integer(), reachability => boolean() }
	
Where:

* `last_activity` encodes when we last had (valid) activity with the node as a point in time.
* `timeout_count` measures how many timeouts we've had since the last succesful communication
* `reachability` encodes if the node has ever replied to one of our queries. If it has, then this field is true. We use the field to track which nodes are behind firewalls and which are not.

This means that for any point in time τ, we can measure the age(T) = τ-T, and
check if the age is larger than, say, ?NODE_TIMEOUT. This defines when a node is
questionable. The timeout_count defines a bad node, if it grows too large.

The meta-data tracks ranges as a single map `Range => #{ timer => timer_ref() }`. When this timer triggers,
we can use the current members of the range and their last activity points. The maximal such value defines the current `age(lists:max(LastActivities))` of the range.

Ranges can exist without any members in them. When this happens, the age of the range is always such that it needs refreshing. We do this by picking the age of the range to be `monotinic_time() - convert_time_unit(?NODE_TIMEOUT, milli_seconds, native)`, which forces the range to refresh.

## Nodes

Nodes are defined as the triple `{id(), ip(), port()}`, where `id()` is the Node ID space (7 bits in test, 160 bit in Kademlia based on sha1, 256bit if based on sha-256). `port()` is the UDP port number, in the usual 0–65535 range. Currently `ip()` is an `ipv4_address()`, but this needs extension to `ipv6_addresses()`.

### Node Equality

TODO: Discussion needed here. Equality is either on the ID or on the Node. The important thing to understand is how this affects roaming nodes which changes address/port but not the ID. How will this affect the routing table and such?

• Equality on NodeID means we can handle the deep end of the routing table easily.

TODO

## Ranges

TODO

Ranges have an age. Suppose we pick the ages of all nodes in the range and sort them, smallest age first. Then the age of the range is the head of that sorted list. A range is refreshable if it's age is larger than 15 minutes. When this happens, we pick a random node from the range and run a FIND_NODE call on it. Once we have a list of nodes near to the randomly picked one, we insert all of these into the routing table. This in turn forces out every bad node, and swaps them with new good nodes.

The assumption is that for normal operation, it is relatively rare a range won't see any kind of traffic for 15 minutes. In other words, a normal, communicating client will not have to refresh ranges very often. But a client who is behind a firewall will have to rely on refreshes a lot in order to keep its routing table alive.

Note that refreshing doesn't evict any nodes by itself. So if the network is down, the routing table will not change. This property is desirable, because it means we don't lose the routing table if our system can't connect to the network for a while.

# Networking

TODO

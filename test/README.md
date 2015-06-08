# Tests and specification of the DHT

This directory contains tests for the DHT system. The tests are captured in the module `dht_SUITE` and running tests will run this suite. The way to run these is from the top-level:

	rebar3 ct

Every test in this project are QuickCheck tests and requires Erlang QuickCheck.

This file contains most of the prose written in order to understand what the specification of the system is. Each module contains further low-level documentation. Do *NOT* rely too much on the text in this file, but refer to the actual specification when in doubt. It is precise, whereas this text is not. For instance, the tests can make the discrimination between `L < 8` and `L ≤8` which is harder to manage with text.

# Test strategy

To make sure the code works as expected, we split the tests into QuickCheck components are start by verifying each component on its own. Once we have individual verfication, we cluster the components using the Erlang QuickCheck `eqc_cluster` feature. In turn, this allows us to handle the full specification from simpler parts.

For each Erlang module, we define a *component* which has a *mocking* *specification* for every call it makes to the outside. This allows us to isolate each module on its own and test it without involving the specification of other modules. We also often overspecify what the module accepts to make sure it works even if the underlying modules change a bit.

Once we have all components, we assemble them into a cluster. Now, the mocking specifications are replaced with actual models. In turn, a callout to a mock can now be verified by the preconditions of the underlying model. This ensures the composition of components are safe.

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

## Routing table

Routing ID's are positive integers. They have a digital bit-representation as lists of bits. These bits form a binary tree structure. The routing table is such a “path” in such a binary tree, considering a prefix of the bit-string. The rules are:

* Leafs have at most 8 nodes
* If inserting a new node into a leaf of size 8, there are two cases:
	* Our own ID has a common prefix `P` with the leaf: Partition the leaf into nodes with prefix `P0` and prefix `P1`. These become the new leafs.
	* Our own ID is not a common prefix with the leaf: reject the insertion.
	
In turn, the routing table is a “spine” in the tree only where the path mimicks our own ID. In turn, the routing table stores more elements close to ourselves rather than far away from ourselves.

TODO: Add documentation

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

### Nodes

We don't track the Node state with a timer. Rather, we note the last succesful point of communication. This means a simple calculation defines when a node becomes questionable, and thus needs a refresh.

The reason we do it this way, is that all refreshes of nodes are event-driven: the node is refreshed whenever it communicates or when we want to use that node. So if we know the point-in-time for last communication, we can determine its internal state, be it `good`, `questionable`, or `bad`.

TODO

### Ranges

TODO



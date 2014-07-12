PROJECT = dht

.DEFAULT_GOAL := all

# Options.
ERLC_OPTS = +debug_info +'{parse_transform, lager_transform}'
PLT_APPS = crypto public_key ssl asn1

# Dependencies.
DEPS = lager benc
dep_lager = https://github.com/basho/lager.git 2.0.3
dep_benc = https://github.com/jlouis/benc.git master


# Standard targets.

analyze:
	@dialyzer ebin --no_native $(DIALYZER_OPTS)

include erlang.mk


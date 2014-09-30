PROJECT = dht

.DEFAULT_GOAL := all

# Options.
ERLC_OPTS = +debug_info +'{parse_transform, lager_transform}'
PLT_APPS = crypto public_key ssl asn1
DIALYZER_OPTS = --fullpath

# Dependencies.
DEPS = lager benc recon
dep_lager = https://github.com/basho/lager.git 2.0.3
dep_benc = https://github.com/jlouis/benc.git master
dep_recon = https://github.com/ferd/recon.git master


# Standard targets.

analyze:
	@dialyzer ebin --no_native $(DIALYZER_OPTS)

# EQC
eqc-ci: all
	erlc -o ebin eqc_test/*.erl

include erlang.mk


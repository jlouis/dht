PROJECT = dht

.DEFAULT_GOAL := all

# Options.
ERLC_OPTS = +debug_info # +'{parse_transform, lager_transform}'
PLT_APPS = crypto public_key ssl asn1
DIALYZER_OPTS = --fullpath

# Dependencies.
DEPS = recon
#dep_lager = https://github.com/basho/lager.git 2.0.3
dep_recon = https://github.com/ferd/recon.git master


# Standard targets.

analyze:
	@dialyzer ebin --no_native $(DIALYZER_OPTS)

# EQC
eqc-ci: all
	rm ebin/*.beam
	cp eqc_test/*.erl src
	mkdir -p ebin
	erl -make

include erlang.mk


VERSION=1.5.1
REQUIRED_ERLANG=R13
ERLANG_VERSION=`erl -eval 'io:format("~s", [erlang:system_info(otp_release)])' -s init stop -noshell`
ERL_ROOT=`erl -eval 'io:format("~s", [code:root_dir()])' -s init stop -noshell`
RTMPDIR=/usr/lib/erlyvideo
VARDIR=/var/lib/erlyvideo
ETCDIR=/etc/erlyvideo
DEBIANREPO=/apps/erlyvideo/debian/public
DESTROOT=$(CURDIR)/debian/erlyvideo

ERL=erl +A 4 +K true
APP_NAME=ems
NODE_NAME=$(APP_NAME)@`hostname`
VSN=0.1
MNESIA_DATA=mnesia-data
MXMLC=mxmlc

all: compile

compile: ebin/mpeg2_crc32.so
	ERL_LIBS=deps:lib:plugins erl -make
	@# for plugin in plugins/* ; do ERL_LIBS=../../lib:../../deps make -C $$plugin; done

	
ebin/mpeg2_crc32.so: lib/mpegts/src/mpeg2_crc32.c
	gcc  -O3 -fPIC -bundle -flat_namespace -undefined suppress -fno-common -Wall -o $@ $< -I $(ERL_ROOT)/usr/include/ || touch $@
	


erlang_version:
	@[ "$(ERLANG_VERSION)" '<' "$(REQUIRED_ERLANG)" ] && (echo "You are using too old erlang: $(ERLANG_VERSION), upgrade to $(REQUIRED_ERLANG)"; exit 1) || true

ebin:
	mkdir ebin

doc:	
	$(ERL) -pa `pwd`/ebin \
	-noshell \
	-run edoc_run application  "'$(APP_NAME)'" '"."' '[{def,{vsn,"$(VSN)"}}]'

clean:
	rm -fv ebin/*.beam ebin/*.so
	rm -fv deps/*/ebin/*.beam
	rm -fv lib/*/ebin/*.beam
	rm -fv plugins/*/ebin/*.beam
	rm -fv erl_crash.dump

clean-doc:
	rm -fv doc/*.html
	rm -fv doc/edoc-info
	rm -fv doc/*.css

player:
	$(MXMLC) -default-background-color=#000000 -default-frame-rate=24 -default-size 960 550 -optimize=true -output=wwwroot/player/player.swf wwwroot/player/player.mxml

run: erlang_version ebin priv/erlmedia.conf
	ERL_LIBS=deps:lib:plugins $(ERL) +bin_opt_info +debug \
	-pa ebin \
	-boot start_sasl \
	-s $(APP_NAME) \
	-mnesia dir "\"${MNESIA_DATA}\"" \
	-name $(NODE_NAME)

priv/erlmedia.conf: priv/erlmedia.conf.sample
	cp priv/erlmedia.conf.sample priv/erlmedia.conf
	
start: erlang_version ebin
	ERL_LIBS=deps:lib:plugins $(ERL) -pa `pwd`/ebin \
	-sasl sasl_error_logger '{file, "sasl.log"}' \
  -kernel error_logger '{file, "erlang.log"}' \
	-boot start_sasl \
	-s $(APP_NAME) \
	-mnesia dir "\"${MNESIA_DATA}\"" \
	-name $(NODE_NAME) \
	-mnesia dir "\"${MNESIA_DATA}\"" \
	-detached

install: compile
	mkdir -p $(DESTROOT)$(BEAMDIR)
	mkdir -p $(DESTROOT)$(DOCDIR)
	mkdir -p $(DESTROOT)$(SRCDIR)
	mkdir -p $(DESTROOT)$(INCLUDEDIR)
	mkdir -p $(DESTROOT)$(ETCDIR)
	mkdir -p $(DESTROOT)$(VARDIR)
	mkdir -p $(DESTROOT)/var/lib/erlyvideo/movies
	cp -r ebin src include lib $(DESTROOT)/usr/lib/erlyvideo
	mkdir -p $(DESTROOT)/usr/bin/
	cp contrib/reverse_mpegts $(DESTROOT)/usr/bin/reverse_mpegts
	cp contrib/erlyctl $(DESTROOT)/usr/bin/erlyctl
	cp -r doc $(DESTROOT)$(DOCDIR)
	mkdir -p $(DESTROOT)/etc/sv/
	cp -r contrib/runit/erlyvideo $(DESTROOT)/etc/sv/
	cp -r wwwroot $(DESTROOT)/var/lib/erlyvideo/
	cp priv/erlmedia.conf.sample $(DESTROOT)/etc/erlyvideo/erlmedia.conf

archive: ../erlyvideo-$(VERSION).tgz
	

../erlyvideo-$(VERSION).tgz:
	(cd ..; tar zcvf erlyvideo-$(VERSION).tgz --exclude='.git*' --exclude='*.log' --exclude=build --exclude=erlyvideo/debian --exclude=erlyvideo/log --exclude='.DS_Store' --exclude='erlyvideo/plugins/*' --exclude=erlyvideo/$(MNESIA_DATA)* --exclude='erlyvideo/*/._*' erlyvideo)

debian: all
	#dpkg-buildpackage
	cp ../erlyvideo_$(VERSION)_*.deb ../erlyvideo_$(VERSION).dsc $(DEBIANREPO)/binary/
	(cd $(DEBIANREPO); dpkg-scanpackages binary /dev/null | gzip -9c > binary/Packages.gz)


.PHONY: doc debian compile


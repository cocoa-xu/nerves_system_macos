.PHONY: all clean

all: priv/hello_native.so

priv/hello_native.so: c_src/hello_native.c
	@test -n "$(ERTS_DIR)" -a -n "$(SDKROOT)" || (echo 'Build with MIX_TARGET=macos and a Nerves system artifact'; exit 1)
	mkdir -p priv
	$(CC) -O2 -Wall -Wextra -Werror -arch arm64 -isysroot "$(SDKROOT)" \
		-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -I"$(ERTS_DIR)/include" \
		-bundle -undefined dynamic_lookup $< -o $@

clean:
	rm -f priv/hello_native.so

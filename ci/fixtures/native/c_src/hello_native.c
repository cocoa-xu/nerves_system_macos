#include <erl_nif.h>
#include <sys/utsname.h>

static ERL_NIF_TERM platform(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    struct utsname info;
    if (uname(&info) != 0) return enif_make_badarg(env);
    return enif_make_tuple2(env,
        enif_make_string(env, info.sysname, ERL_NIF_LATIN1),
        enif_make_string(env, info.machine, ERL_NIF_LATIN1));
}

static ErlNifFunc functions[] = {{"platform", 0, platform, 0}};
ERL_NIF_INIT(Elixir.HelloMacOS.Native, functions, NULL, NULL, NULL, NULL)

/* SPDX-License-Identifier: MIT
 *
 * modules/reliquary/arca/shim.c -- the one symbol arca.gen.c imports.
 *
 * arca.gen.c is an Exsecutor library unit (exsc --emitte c): no entry point,
 * no runtime, one import. exsrt_abortus is reached only by a bounds or
 * overflow trap, and src/arca.rs passes nothing that traps, so reaching it is
 * a defect in the judge. A judge that has failed must not be trusted to have
 * judged, and the prototype is _Noreturn: the process stops. reliquary is
 * root here, mid-extract, BEFORE tar has run -- stopping is the safe end. */
#include <stdio.h>
#include <stdlib.h>

_Noreturn void exsrt_abortus(unsigned kind);

_Noreturn void exsrt_abortus(unsigned kind)
{
  fprintf(stderr, "reliquary: arca tar judge trapped (exsrt_abortus %u); stopping before extract\n", kind);
  abort();
}

/* SPDX-License-Identifier: MPL-2.0
 *
 * modules/oligarchy-plugins/potestas-cert/potestas/shim.c -- the one symbol
 * potestas.gen.c imports.
 *
 * potestas.gen.c is an Exsecutor library unit (exsc --emitte c): no entry
 * point, no runtime, one import. exsrt_abortus is reached only by a bounds
 * or overflow trap, and nothing the certification passes may trap -- so
 * reaching it is a defect, and the test process stops. */
#include <stdio.h>
#include <stdlib.h>

_Noreturn void exsrt_abortus(unsigned kind);

_Noreturn void exsrt_abortus(unsigned kind)
{
  fprintf(stderr, "potestas-cert: Exsecutor unit trapped (exsrt_abortus %u)\n", kind);
  abort();
}

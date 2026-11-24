#include <stdio.h>
__attribute__((constructor)) static void injected(void){fputs("KURO_ELECTRON_DYLD_ATTACK_MARKER\n",stderr);}

/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
#include "clean.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    const char *target = (argc > 1) ? argv[1] : ".";
    return clean(target);
}

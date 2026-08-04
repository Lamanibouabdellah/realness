/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
#include <stdio.h>
#include <stdlib.h>
#include <ftw.h>

/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
static int delete_cb(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftwbuf)
{
    (void)sb;
    if (ftwbuf->level == 0) return 0;
    int rc;
    switch (typeflag) {
        case FTW_DP: rc = rmdir(fpath); break;
        case FTW_F:  rc = unlink(fpath); break;
        case FTW_NS: rc = unlink(fpath); break;
        default:     rc = 0; break;
    }
    if (rc != 0) fprintf(stderr, "error: %s\n", fpath);
    return rc;
}

/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <directory>\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (nftw(argv[1], delete_cb, 20, FTW_DEPTH | FTW_PHYS) == -1) {
        fprintf(stderr, "error: cannot open %s\n", argv[1]);
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

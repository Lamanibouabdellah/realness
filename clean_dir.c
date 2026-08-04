/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
#include <stdio.h>
#include <stdlib.h>
#include <ftw.h>

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

int clean_dir(const char *path)
{
    if (nftw(path, delete_cb, 20, FTW_DEPTH | FTW_PHYS) == -1) {
        fprintf(stderr, "error: cannot open %s\n", path);
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

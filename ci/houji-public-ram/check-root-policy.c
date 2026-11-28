#include <assert.h>
#include "HoujiRootFs26.h"

int main(void)
{
    assert(hjrfs26_candidate(0, 1, "mockfs"));
    assert(!hjrfs26_candidate(0, 1, "hfs"));
    assert(hjrfs26_candidate(0, 0, "hfs"));
    assert(!hjrfs26_candidate(0, 0, "mockfs"));
    assert(hjrfs26_candidate(1, 1, "hfs"));
    assert(!hjrfs26_candidate(1, 1, "mockfs"));
    assert(!hjrfs26_candidate(0, 1, "mockfs2"));
    assert(!hjrfs26_candidate(1, 0, 0));
    return 0;
}

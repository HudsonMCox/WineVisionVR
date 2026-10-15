#include "WindowsVRCompletionWindow.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <set>

int main() {
    for (const uint64_t base : {uint64_t{0}, UINT64_MAX - 6}) {
        std::array<unsigned, 6> order{1,2,3,4,5,6};
        do {
            uint64_t last=base, mask=0, expected=base;
            std::set<uint64_t> reference;
            for (unsigned offset : order) {
                const uint64_t ticket=base+offset;
                reference.insert(ticket);
                while (expected != UINT64_MAX && reference.erase(expected+1)) ++expected;
                wvrCompleteTicket(ticket,last,mask);
                assert(last==expected);
                // A duplicate cannot advance the contiguous fence again.
                assert(!wvrCompleteTicket(ticket,last,mask));
                assert(last==expected);
            }
            assert(last==base+6 && mask==0);
        } while (std::next_permutation(order.begin(),order.end()));
    }
    uint64_t last=0, mask=0;
    for (uint64_t ticket=1;ticket<=100000;++ticket) {
        assert(wvrCompleteTicket(ticket,last,mask));
        assert(last==ticket && !mask);
    }
    puts("PASS: all 720 completion orders, duplicates, uint64 boundary and 100000 sequential retirements; fixed storage, no allocation");
}

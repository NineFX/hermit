#include <stddef.h>
#include <stdint.h>

uint32_t c_checksum(const uint8_t *data, size_t len) {
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i++) {
        sum = sum * 31 + data[i];
    }
    return sum;
}

//
//  tar_types.h
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

#include <stdint.h>

typedef struct __attribute__((packed)) {
    char name[100];     // Offset 0
    char mode[8];       // Offset 100
    char uid[8];        // Offset 108
    char gid[8];        // Offset 116
    char size[12];      // Offset 124 (Octal ASCII)
    char mtime[12];     // Offset 136
    char chksum[8];     // Offset 148
    char typeflag;      // Offset 156
    char linkname[100]; // Offset 157
    char magic[6];      // Offset 257 ("ustar\0")
    char version[2];    // Offset 263 ("00")
    
    char uname[32];     // Username
    char gname[32];     // Name group
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    
    char pad[12];       // Padding for 512 byte
} tar_header_t;

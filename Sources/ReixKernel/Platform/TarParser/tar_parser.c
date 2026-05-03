//
//  tar_parser.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/05/2026.
//

#include "tar_types.h"
#include "stdint.h"
#include "stdbool.h"

uint32_t get_file_size(tar_header_t* header);
bool     is_file_section(const char* name_file, tar_header_t* header);

uint64_t parse_tar(const char* name_file, uint64_t address) {
    if (!name_file) { return 0; }
    
    tar_header_t* header_ptr = (tar_header_t*)address;
    while(header_ptr->name[0] != 0) {
        if (is_file_section(name_file, header_ptr)) {
            return (uint64_t)header_ptr + 512;
        }
        
        uint32_t size = get_file_size(header_ptr);
        uint32_t size_aligned = (size + 511) & ~511;
        
        uint64_t next_header_addr = (uint64_t)header_ptr + 512 + size_aligned;
        header_ptr = (tar_header_t*)next_header_addr;
    }
    
    return 0;
}

uint32_t get_file_size(tar_header_t* header) {
    
    uint32_t result = 0;
    for (uint8_t i = 0; i < 12; i++) {
        char character = header->size[i];        
        if (character < '0' || character > '7') continue;
        result = (result << 3) + (character - '0');
    }
    
    return result;
}

bool is_file_section(const char* name_file, tar_header_t* header) {
    
    bool     result        = true;
    char*    current       = (char*)name_file;
    uint32_t iterator_name = 0;
    while ((*current) != '\0' && result == true) {
        
        if ((*current) != header->name[iterator_name]) {
            result = false;
            break;
        }
        
        iterator_name++;
        current++;
    }
    
    return result;
}

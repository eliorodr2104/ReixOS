#include <stdarg.h>
#include <stdint.h>

void reverse(char s[], int size) {
    int i, j;
    char c;
    for (i = 0, j = size-1; i < j; i++, j--) {
        c = s[i];
        s[i] = s[j];
        s[j] = c;
    }
}

void utoa_hex(uint64_t n, char s[]) {
    int i = 0;
    char digits[] = "0123456789ABCDEF";
    if (n == 0) s[i++] = '0';
    while (n > 0) {
        s[i++] = digits[n % 16];
        n /= 16;
    }
    s[i] = '\0';
    reverse(s, i);
}

void utoa_dec(uint64_t n, char s[]) {
    int i = 0;
    if (n == 0) s[i++] = '0';
    while (n > 0) {
        s[i++] = n % 10 + '0';
        n /= 10;
    }
    s[i] = '\0';
    reverse(s, i);
}

char* stringFormat(char* fmt, ...) {
    static char buffer[256];
    unsigned int iterator = 0;
    va_list list;
    char* ptr = fmt;
    char temp[32];
    char* t_ptr;
    
    va_start(list, fmt);
    while (*ptr) {
        if (*ptr == '%') {
            ptr++;
            switch (*ptr) {
            case 'd': // Trattiamo d come unsigned 64bit per semplicità nel kernel
                utoa_dec(va_arg(list, uint64_t), temp);
                t_ptr = temp;
                while (*t_ptr) buffer[iterator++] = *t_ptr++;
                break;
                
            case 'x': // Nuovo: Formato Esadecimale
            case 'X':
                utoa_hex(va_arg(list, uint64_t), temp);
                t_ptr = temp;
                while (*t_ptr) buffer[iterator++] = *t_ptr++;
                break;
                
            case 'c':
                buffer[iterator++] = (char)va_arg(list, int);
                break;
            }
        } else {
            buffer[iterator++] = *ptr;
        }
        ptr++;
    }
    
    buffer[iterator] = '\0';
    va_end(list);
    
    return buffer;
}

char* format1(char* fmt, uint64_t a) { return stringFormat(fmt, a); }
char* format2(char* fmt, uint64_t a, uint64_t b) { return stringFormat(fmt, a, b); }
char* format3(char* fmt, uint64_t a, uint64_t b, uint64_t c) { return stringFormat(fmt, a, b, c); }

char* format4(char* fmt, uint64_t a, uint64_t b, uint64_t c, uint64_t d) { return stringFormat(fmt, a, b, c, d); }

#if defined(__linux__) && defined(__x86_64__)
__asm__(".symver log10f_compat,log10f@GLIBC_2.2.5");
extern float log10f_compat(float);

float __wrap_log10f(float x) {
    return log10f_compat(x);
}
#endif

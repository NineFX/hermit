#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

EXPORT const char *greet_message(void) {
    return "hello from the greet library";
}

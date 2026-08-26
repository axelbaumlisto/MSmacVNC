/* Compiled into every test target and into macvnc_core_testable. If NDEBUG
   survives anywhere in that chain, the build fails HERE - a previous guard
   checked a CMake property it had set itself two lines earlier and could
   never fire. */
#ifdef NDEBUG
#error "test target built with NDEBUG: assertions are compiled out"
#endif

when not defined(NimGoNoThreadSupport):
    switch("threads", "on")
    switch("define", "threadsafe")

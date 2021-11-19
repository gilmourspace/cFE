cmake_minimum_required (VERSION 3.15.3)

# projectname is the same as the main-executable
project(CFESWIFT)

#set(SWIFT_ALL_LIBS swiftCore util m swiftSwiftOnoneSupport icui18nswift icuucswift icudataswift stdc++ gcc_s)

set(SWIFT_LIBS swiftCore swiftSwiftOnoneSupport icui18nswift icuucswift icudataswift)

set(SWIFT_SYSTEM_LIBS util m stdc++ gcc_s)

set(SWIFT_ALL_LIBS ${SWIFT_LIBS} ${SWIFT_SYSTEM_LIBS})

set(TARGET_LINK_FLAGS ${TARGET_LINK_FLAGS} "-Wl,-R/usr/lib/swift/linux" "-Wl,-L/usr/lib/swift/linux")

foreach(SWIFTLIB ${SWIFT_LIBS})
    add_library(${SWIFTLIB} SHARED IMPORTED)
    set_target_properties(${SWIFTLIB} PROPERTIES IMPORTED_LOCATION "/usr/lib/swift/linux/lib${SWIFTLIB}")
endforeach()



##################################################################
#
# Core Flight System architecture-specific build recipes
#
# This file is invoked by the top-level mission recipe for
# to build cFE/cFS for each target processor
#
# Note that the target CPUs may use different architectures, therefore each
# architecture must be done as a separate sub-build since none of the binaries
# can be shared.
#
##################################################################

# define a custom property to track dependencies on CFE module targets.
# users should not typically manipulate this directly
define_property(TARGET PROPERTY CFE_MODULE_DEPENDENCIES
    BRIEF_DOCS
        "A set of CFE module dependencies"
    FULL_DOCS
        "This is a CFE-specific target property that is added to CFE modules that contains the module dependencies"
)


##################################################################
#
# FUNCTION: initialize_globals
#
# Set up global mission configuration variables.
# This function determines the mission configuration directory and
# also reads any startup state info from file(s) on the disk
#
# In the CPU (cross) build this only reads a cache file that was
# generated by the mission (top-level) build.  Therefore all
# architecture-specific cross builds will get the same settings.
#
function(initialize_globals)

  # Sanity check -- the parent build script should have set MISSION_BINARY_DIR
  if (NOT IS_DIRECTORY "${MISSION_BINARY_DIR}")
      message(FATAL_ERROR "BUG -- MISSION_BINARY_DIR not a valid directory in arch_build.cmake")
  endif()

  # Read the variable values from the cache file.
  set(MISSION_IMPORTED_VARS)
  file(READ "${MISSION_BINARY_DIR}/mission_vars.cache" PARENTVARS)
  string(REGEX REPLACE ";" "\\\\;" PARENTVARS "${PARENTVARS}")
  string(REGEX REPLACE "\n" ";" PARENTVARS "${PARENTVARS}")
  foreach(PV ${PARENTVARS})
    if (VARNAME)
      set(${VARNAME} ${PV} PARENT_SCOPE)
      list(APPEND MISSION_IMPORTED_VARS ${VARNAME})
      unset(VARNAME)
    else()
      set(VARNAME ${PV})
    endif()
  endforeach(PV ${PARENTVARS})
  unset(VARNAME)
  unset(PARENTVARS)
  set(MISSION_IMPORTED_VARS ${MISSION_IMPORTED_VARS} PARENT_SCOPE)

endfunction(initialize_globals)


##################################################################
#
# FUNCTION: add_psp_module
#
# Simplified routine to add a driver to the PSP in use on this arch
# Called by module listfiles
#
function(add_psp_module MOD_NAME MOD_SRC_FILES)

  # Create the module
  add_library(${MOD_NAME} STATIC ${MOD_SRC_FILES} ${ARGN})
  target_link_libraries(${MOD_NAME} PRIVATE psp_module_api)

  target_compile_definitions(${MOD_NAME} PRIVATE
    _CFE_PSP_MODULE_
  )

endfunction(add_psp_module)

##################################################################
#
# FUNCTION: add_cfe_app
#
# Simplified routine to add a CFS app or lib this arch
# Called by module listfiles
#
function(add_cfe_app APP_NAME APP_SRC_FILES)

  # currently this will build an app with either static linkage or shared/module linkage,
  # but this does not currently support both for a single arch (could be revised if that is needed)
  if (APP_DYNAMIC_TARGET_LIST)
     set(APPTYPE "MODULE")
  else()
     set(APPTYPE "STATIC")
  endif()

  message(STATUS "ARGN ${ARGN}")

  message("CFE App CMAKE_LINKER: ${CMAKE_LINKER}")

  # Create the app module
  add_library(${APP_NAME} ${APPTYPE} ${APP_SRC_FILES} ${ARGN})
  message(STATUS "Done add library")
  target_link_libraries(${APP_NAME} core_api)
  string(REPLACE " " ";" LINK_OPTIONS ${CMAKE_SHARED_LINKER_FLAGS})
  target_link_options(${APP_NAME} PUBLIC ${LINK_OPTIONS})
  message(STATUS "Done link libraries")

  # An "install" step is only needed for dynamic/runtime loaded apps
  if (APP_DYNAMIC_TARGET_LIST)
    cfs_app_do_install(${APP_NAME} ${APP_DYNAMIC_TARGET_LIST})
  endif (APP_DYNAMIC_TARGET_LIST)
  message(STATUS "Fin add_cfe_app")

endfunction(add_cfe_app)

##################################################################
#
# FUNCTION: add_cfe_app_dependency
#
# Adds a library dependency to a previously-created
# app/library target
#
# it adds the interface include directories and compile definitions
# of the dependency into the compilation for the module.
#
function(add_cfe_app_dependency MODULE_NAME DEPENDENCY_MODULE)

    # assemble a list of include directories and compile definitions
    set(INCLUDE_LIST)
    set(COMPILE_DEF_LIST)
    foreach(DEP ${DEPENDENCY_MODULE} ${ARGN})
        list(APPEND INCLUDE_LIST "$<TARGET_PROPERTY:${DEPENDENCY_MODULE},INTERFACE_INCLUDE_DIRECTORIES>")
        list(APPEND COMPILE_DEF_LIST "$<TARGET_PROPERTY:${DEPENDENCY_MODULE},INTERFACE_COMPILE_DEFINITIONS>")
    endforeach()

    target_include_directories(${MODULE_NAME} PUBLIC
        ${INCLUDE_LIST}
    )
    target_compile_definitions(${MODULE_NAME} PUBLIC
        ${COMPILE_DEF_LIST}
    )

    # append to the custom property to track this dependency (this helpful for UT)
    set_property(TARGET ${MODULE_NAME} APPEND PROPERTY CFE_MODULE_DEPENDENCIES ${DEPENDENCY_MODULE} ${ARGN})

endfunction(add_cfe_app_dependency)

##################################################################
#
# FUNCTION: add_cfe_tables
#
# Simplified routine to add CFS tables to be built with an app
#
function(add_cfe_tables APP_NAME TBL_SRC_FILES)

    if (TGTNAME)
        set (TABLE_TGTLIST ${TGTNAME})
    elseif (TARGET ${APP_NAME})
        set (TABLE_TGTLIST ${TGTLIST_${APP_NAME}})
    else()
        # The first parameter should match the name of an app that was
        # previously defined using "add_cfe_app".  If target-scope properties
        # are used for include directories and compile definitions, this is needed
        # to compile tables with the same include path/definitions as the app has.
        # However historically this could have been any string, which still works
        # if directory-scope properties are used for includes, so this is not
        # an error.
        message("NOTE: \"${APP_NAME}\" passed to add_cfe_tables is not a previously-defined application target")
        set (TABLE_TGTLIST ${APP_STATIC_TARGET_LIST} ${APP_DYNAMIC_TARGET_LIST})
    endif()

    # The table source must be compiled using the same "include_directories"
    # as any other target, but it uses the "add_custom_command" so there is
    # no automatic way to do this (at least in the older cmakes)

    # Create the intermediate table objects using the target compiler,
    # then use "elf2cfetbl" to convert to a .tbl file
    foreach(TBL ${TBL_SRC_FILES} ${ARGN})

        # Get name without extension (NAME_WE) and append to list of tables
        get_filename_component(TBLWE ${TBL} NAME_WE)

        foreach(TGT ${TABLE_TGTLIST})
            set(TABLE_LIBNAME "${TGT}_${APP_NAME}_${TBLWE}")
            set(TABLE_DESTDIR "${CMAKE_CURRENT_BINARY_DIR}/${TABLE_LIBNAME}")
            set(TABLE_BINARY  "${TABLE_DESTDIR}/${TBLWE}.tbl")
            file(MAKE_DIRECTORY ${TABLE_DESTDIR})

            # Check if an override exists at the mission level (recommended practice)
            # This allows a mission to implement a customized table without modifying
            # the original - this also makes for easier merging/updating if needed.
            if (EXISTS "${MISSION_DEFS}/tables/${TGT}_${TBLWE}.c")
                set(TBL_SRC "${MISSION_DEFS}/tables/${TGT}_${TBLWE}.c")
            elseif (EXISTS "${MISSION_SOURCE_DIR}/tables/${TGT}_${TBLWE}.c")
                set(TBL_SRC "${MISSION_SOURCE_DIR}/tables/${TGT}_${TBLWE}.c")
            elseif (EXISTS "${MISSION_DEFS}/${TGT}/tables/${TBLWE}.c")
                set(TBL_SRC "${MISSION_DEFS}/${TGT}/tables/${TBLWE}.c")
            elseif (EXISTS "${MISSION_DEFS}/tables/${TBLWE}.c")
                set(TBL_SRC "${MISSION_DEFS}/tables/${TBLWE}.c")
            elseif (EXISTS "${MISSION_SOURCE_DIR}/tables/${TBLWE}.c")
                set(TBL_SRC "${MISSION_SOURCE_DIR}/tables/${TBLWE}.c")
            elseif (IS_ABSOLUTE "${TBL}")
                set(TBL_SRC "${TBL}")
            else()
                set(TBL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/${TBL}")
            endif()

            if (NOT EXISTS "${TBL_SRC}")
                message(FATAL_ERROR "ERROR: No source file for table ${TBLWE}")
            else()
                message("NOTE: Selected ${TBL_SRC} as source for ${APP_NAME}.${TBLWE} on ${TGT}")

                # NOTE: On newer CMake versions this should become an OBJECT library which makes this simpler.
                # On older versions one may not reference the TARGET_OBJECTS property from the custom command.
                # As a workaround this is built into a static library, and then the desired object is extracted
                # before passing to elf2cfetbl.  It is roundabout but it works.
                add_library(${TABLE_LIBNAME} STATIC ${TBL_SRC})
                target_link_libraries(${TABLE_LIBNAME} PRIVATE core_api)
                if (TARGET ${APP_NAME})
                    target_include_directories(${TABLE_LIBNAME} PRIVATE $<TARGET_PROPERTY:${APP_NAME},INCLUDE_DIRECTORIES>)
                    target_compile_definitions(${TABLE_LIBNAME} PRIVATE $<TARGET_PROPERTY:${APP_NAME},COMPILE_DEFINITIONS>)
                endif()

                # IMPORTANT: This rule assumes that the output filename of elf2cfetbl matches
                # the input file name but with a different extension (.o -> .tbl)
                # The actual output filename is embedded in the source file (.c), however
                # this must match and if it does not the build will break.  That's just the
                # way it is, because NO make system supports changing rules based on the
                # current content of a dependency (rightfully so).
                add_custom_command(
                    OUTPUT ${TABLE_BINARY}
                    COMMAND ${CMAKE_COMMAND}
                        -DCMAKE_AR=${CMAKE_AR}
                        -DTBLTOOL=${MISSION_BINARY_DIR}/tools/elf2cfetbl/elf2cfetbl
                        -DLIB=$<TARGET_FILE:${TABLE_LIBNAME}>
                        -P ${CFE_SOURCE_DIR}/cmake/generate_table.cmake
                    DEPENDS ${MISSION_BINARY_DIR}/tools/elf2cfetbl/elf2cfetbl ${TABLE_LIBNAME}
                    WORKING_DIRECTORY ${TABLE_DESTDIR}
                )

                # Add a custom target to invoke the elf2cfetbl tool to generate the tbl file,
                # and install that binary file to the staging area.
                add_custom_target(${TABLE_LIBNAME}_tbl ALL DEPENDS ${TABLE_BINARY})
                install(FILES ${TABLE_BINARY} DESTINATION ${TGT}/${INSTALL_SUBDIR})
            endif()
        endforeach()
    endforeach()


endfunction(add_cfe_tables)

##################################################################
#
# FUNCTION: add_cfe_coverage_dependency
#
# Adds a stub library dependency to a previously-created
# coverage test runner target
#
# If a unit under test calls functions provided by another unit
# (such as a library) then the stubs from that library will be
# added to the LINK_LIBRARIES of the coverage test.
#
function(add_cfe_coverage_dependency MODULE_NAME UNIT_NAME DEPENDENCY_MODULE)

    # the stub library correlating to the module should be named:
    #   coverage-${MODULE_NAME}-stubs
    # (assuming it was added by the add_cfe_coverage_stubs above)
    set(DEP_LIST)
    foreach(DEP ${DEPENDENCY_MODULE} ${ARGN})
        list(APPEND DEP_LIST "coverage-${DEP}-stubs")
    endforeach()

    target_link_libraries(coverage-${MODULE_NAME}-${UNIT_NAME}-testrunner
        ${DEP_LIST}
    )

endfunction(add_cfe_coverage_dependency)


##################################################################
#
# FUNCTION: add_cfe_coverage_test
#
# Add executable target for coverage testing.  This builds the target
# units with extra compiler flags for coverage instrumentation, along with
# a "testrunner" executable to run the tests.  It also registers
# that testrunner with ctest via the add_test() function.
#
# NOTE: The first argument (MODULE_NAME) must match the name that was previously
# passed to the add_cfe_app() function - as this references that previous
# target to use the same compile definitions and include paths.
#
# The executable target name follows the pattern:
#    "coverage-${MODULE_NAME}-${UNIT_NAME}-testrunner"
#
# The calling script may call target_link_libraries() (or other target functions)
# to customize this target as needed.
#
function(add_cfe_coverage_test MODULE_NAME UNIT_NAME TESTCASE_SRC UT_SRCS)

    # A consistent name convention for all targets generated by this function
    set(TEST_NAME "coverage-${MODULE_NAME}-${UNIT_NAME}")
    set(OBJECT_TARGET "${TEST_NAME}-object")
    set(RUNNER_TARGET "${TEST_NAME}-testrunner")

    # Compile the source unit(s) under test as a separate library
    # This is done so that special coverage-specific compile flags can be used on these files
    add_library(${OBJECT_TARGET} OBJECT
        ${UT_SRCS} ${ARGN}
    )

    # Apply the UT_COVERAGE_COMPILE_FLAGS to the units under test
    # This should enable coverage analysis on platforms that support this
    target_compile_options(${OBJECT_TARGET} PRIVATE
        ${UT_COVERAGE_COMPILE_FLAGS}
    )

    # Include the same set of include dirs/definitions that is used from the app target
    target_include_directories(${OBJECT_TARGET} PUBLIC
        $<TARGET_PROPERTY:${MODULE_NAME},INCLUDE_DIRECTORIES>
    )
    target_compile_definitions(${OBJECT_TARGET} PUBLIC
        $<TARGET_PROPERTY:${MODULE_NAME},COMPILE_DEFINITIONS>
    )

    # Compile a test runner application, which contains the
    # actual coverage test code (test cases) and the unit under test
    add_executable(${RUNNER_TARGET}
        ${TESTCASE_SRC}
        $<TARGET_OBJECTS:${OBJECT_TARGET}>
    )

    # Include the same set of include dirs/definitions that is used from the app target
    target_include_directories(${RUNNER_TARGET} PUBLIC
        $<TARGET_PROPERTY:${MODULE_NAME},INCLUDE_DIRECTORIES>
    )
    target_compile_definitions(${RUNNER_TARGET} PUBLIC
        $<TARGET_PROPERTY:${MODULE_NAME},COMPILE_DEFINITIONS>
    )

    # This also needs to be linked with UT_COVERAGE_LINK_FLAGS (for coverage)
    # This is also linked with any other stub libraries needed,
    # as well as the UT assert framework
    target_link_libraries(${RUNNER_TARGET}
        ${UT_COVERAGE_LINK_FLAGS}
        ut_core_api_stubs
        ut_assert
    )

    # for whatever app/lib dependencies the real FSW app had, the unit test
    # should have the same dependencies but on the stubs instead.
    get_target_property(MODULE_DEPENDENCIES ${MODULE_NAME} CFE_MODULE_DEPENDENCIES)
    if (MODULE_DEPENDENCIES)
        add_cfe_coverage_dependency(${MODULE_NAME} ${UNIT_NAME} ${MODULE_DEPENDENCIES})
    endif(MODULE_DEPENDENCIES)

    # Add it to the set of tests to run as part of "make test"
    add_test(${TEST_NAME} ${RUNNER_TARGET})
    foreach(TGT ${INSTALL_TARGET_LIST})
        install(TARGETS ${RUNNER_TARGET} DESTINATION ${TGT}/${UT_INSTALL_SUBDIR})
    endforeach()

endfunction(add_cfe_coverage_test)


##################################################################
#
# FUNCTION: add_cfe_coverage_unit_include
#
# Add an "override" include directory for a specific unit test
#
# This can be used if a coverage test needs to override certain
# C library header files only for a specific unit under test.  The
# include path is added only for the particular source files in the
# specified coverage test unit.  (Not for the coverage test itself).
#
# The executable target name follows the pattern:
#    "coverage-${MODULE_NAME}-${UNIT_NAME}-testrunner"
#
function(add_cfe_coverage_unit_include MODULE_NAME UNIT_NAME OVERRIDE_INCLUDE_DIRS)
    # For the object target only, the "override" includes should be injected
    # into the include path.  Note it is important that this is only included
    # for the specific unit under test (object lib) not the coverage
    # test executable or test cases, since these typically need the real
    # version of these functions.
    target_include_directories(coverage-${MODULE_NAME}-${UNIT_NAME}-object PRIVATE
        ${OVERRIDE_INCLUDE_DIRS} ${ARGN}
    )

endfunction(add_cfe_coverage_unit_include)


##################################################################
#
# FUNCTION: add_cfe_coverage_stubs
#
# Add stub library target for coverage testing.  The stub library should
# contain a stub implementation for every function defined in the public
# API of the current module.
#
# NOTE: The first argument (MODULE_NAME) should match a name that was previously
# passed to the add_cfe_app() function - as this references that previous
# target to use the same compile definitions and include paths.
# (however this does also allow extra stub libs to be created that are not
# related to an existing module)
#
# The stub library target name follows the pattern:
#    "coverage-${MODULE_NAME}-stubs"
#
# The calling script may call target_link_libraries() (or other target functions)
# to customize this target as needed.
#
# NOTE: To simplify linking and avoid possible problems there should ideally be a 1:1
# relationship between module source files and the stub files.  Each stub file
# should provide the same set of functions that the fsw source file provides.
# (although its is not strictly required, it does help keep things more manageable).
#
function(add_cfe_coverage_stubs MODULE_NAME STUB_SRCS)

    set(STUB_TARGET "coverage-${MODULE_NAME}-stubs")

    add_library(${STUB_TARGET} STATIC
        ${STUB_SRCS} ${ARGN}
    )

    # If the MODULE_NAME refers to an existing CFE APP/LIB target, then
    # use the same set of include dirs/definitions that is used from the app target
    # This is not required; "extra" stub libs may be created that are not
    # directly associated with an existing module.
    if (TARGET ${MODULE_NAME})
        target_include_directories(${STUB_TARGET} PUBLIC
            $<TARGET_PROPERTY:${MODULE_NAME},INCLUDE_DIRECTORIES>
        )
        target_compile_definitions(${STUB_TARGET} PUBLIC
            $<TARGET_PROPERTY:${MODULE_NAME},COMPILE_DEFINITIONS>
        )
    endif()

    target_link_libraries(${STUB_TARGET} ut_assert)

endfunction(add_cfe_coverage_stubs)


##################################################################
#
# FUNCTION: cfe_exec_do_install
#
# Called to install a CFE core executable target to the staging area.
# Some architectures/OS's need special extra steps, and this
# function can be overridden in a custom cmake file for those platforms
#
function(cfe_exec_do_install CPU_NAME)

    # By default just stage it to a directory of the same name
    install(TARGETS core-${CPU_NAME} DESTINATION ${CPU_NAME})

endfunction(cfe_exec_do_install)

##################################################################
#
# FUNCTION: cfs_app_do_install
#
# Called to install a CFS application target to the staging area.
# Some architectures/OS's need special extra steps, and this
# function can be overridden in a custom cmake file for those platforms
#
function(cfs_app_do_install APP_NAME)

    # override the default behavior of attaching a "lib" prefix
    set_target_properties(${APP_NAME} PROPERTIES
        PREFIX "" OUTPUT_NAME "${APP_NAME}")

    # Create the install targets for this shared/modular app
    foreach(TGT ${ARGN})
      install(TARGETS ${APP_NAME} DESTINATION ${TGT}/${INSTALL_SUBDIR})
    endforeach()

endfunction(cfs_app_do_install)

##################################################################
#
# FUNCTION: cfs_app_check_intf
#
# Adds a special target that checks the structure of header files
# in the public interface for this module.  A synthetic .c source file
# is created which has a "#include" of each individual header, which
# then compiled as part of the validation.  The intent is to confirm
# that each header is valid in a standalone fashion and have no
# implicit prerequisites.
#
function(cfs_app_check_intf MODULE_NAME)
    set(${MODULE_NAME}_hdrcheck_SOURCES)
    foreach(HDR ${ARGN})
        configure_file(${CFE_SOURCE_DIR}/cmake/check_header.c.in ${CMAKE_CURRENT_BINARY_DIR}/src/check_${HDR}.c)
        list(APPEND ${MODULE_NAME}_hdrcheck_SOURCES ${CMAKE_CURRENT_BINARY_DIR}/src/check_${HDR}.c)
    endforeach(HDR ${ARGN})
    add_library(${MODULE_NAME}_headercheck STATIC EXCLUDE_FROM_ALL ${${MODULE_NAME}_hdrcheck_SOURCES})

    # This causes the check to compile with the same set of defines and include dirs as specified
    # in the "INTERFACE" properties of the actual module
    target_link_libraries(${MODULE_NAME}_headercheck PRIVATE
        core_api
        ${DEP}
    )

    # Build this as part of the synthetic "check-headers" target
    add_dependencies(check-headers ${MODULE_NAME}_headercheck)
endfunction(cfs_app_check_intf)




##################################################################
#
# FUNCTION: prepare
#
# Called by the top-level CMakeLists.txt to set up prerequisites
#
function(prepare)

  # Choose the configuration file to use for OSAL on this system
  set(OSAL_CONFIGURATION_FILE)
  foreach(CONFIG ${BUILD_CONFIG_${TARGETSYSTEM}} ${OSAL_SYSTEM_OSCONFIG})
    if (EXISTS "${MISSION_DEFS}/${CONFIG}_osconfig.cmake")
      list(APPEND OSAL_CONFIGURATION_FILE "${MISSION_DEFS}/${CONFIG}_osconfig.cmake")
    endif()
  endforeach()
  list(REVERSE OSAL_CONFIGURATION_FILE)
  set(OSAL_CONFIGURATION_FILE ${OSAL_CONFIGURATION_FILE} PARENT_SCOPE)

  # Allow sources to "ifdef" certain things if running on simulated hardware
  # This should be used sparingly, typically to fake access to hardware that is not present
  if (SIMULATION)
    add_definitions(-DSIMULATION=${SIMULATION})
  endif (SIMULATION)

  # Check that PSPNAME is set properly for this arch
  if (NOT CFE_SYSTEM_PSPNAME)
    if (CMAKE_CROSSCOMPILING)
      message(FATAL_ERROR "Cross-compile toolchain ${CMAKE_TOOLCHAIN_FILE} must define CFE_SYSTEM_PSPNAME")
    elseif ("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux" OR
            "${CMAKE_SYSTEM_NAME}" STREQUAL "CYGWIN")
      # Export the variables determined here up to the parent scope
      SET(CFE_SYSTEM_PSPNAME      "pc-linux" PARENT_SCOPE)
    else ()
      # Not cross compiling and host system is not recognized
      message(FATAL_ERROR "Do not know how to set CFE_SYSTEM_PSPNAME on ${CMAKE_SYSTEM_NAME} system")
    endif()
  endif (NOT CFE_SYSTEM_PSPNAME)

  # Truncate the global TGTSYS_LIST to be only the target architecture
  set(TGTSYS_LIST ${TARGETSYSTEM} PARENT_SCOPE)

  # set the BUILD_CONFIG variable from the cached data
  set(BUILD_CONFIG ${BUILD_CONFIG_${TARGETSYSTEM}})
  list(REMOVE_AT BUILD_CONFIG 0)
  set(BUILD_CONFIG ${BUILD_CONFIG} PARENT_SCOPE)

  # Pull in any application-specific platform-scope configuration
  # This may include user configuration files such as cfe_platform_cfg.h,
  # or any other configuration/preparation that needs to happen at
  # platform/arch scope.
  foreach(DEP_NAME ${MISSION_DEPS})
    include("${${DEP_NAME}_MISSION_DIR}/arch_build.cmake" OPTIONAL)
  endforeach(DEP_NAME ${MISSION_DEPS})

endfunction(prepare)


##################################################################
#
# FUNCTION: process_arch
#
# Called by the top-level CMakeLists.txt to set up targets for this arch
# This is where the real work is done
#
function(process_arch SYSVAR)

  # Check if something actually uses this arch;
  # if this list is empty then do nothing, skip building osal/psp
  if (NOT DEFINED TGTSYS_${SYSVAR})
    return()
  endif()

  # Generate a list of targets that share this system architecture
  set(INSTALL_TARGET_LIST ${TGTSYS_${SYSVAR}})

  # Assume use of an OSAL BSP of the same name as the CFE PSP
  # This can be overridden by the PSP-specific build_options but normally this is expected.
  set(CFE_PSP_EXPECTED_OSAL_BSPTYPE ${CFE_SYSTEM_PSPNAME})

  # Include any specific compiler flags or config from the selected PSP
  include(${psp_MISSION_DIR}/fsw/${CFE_SYSTEM_PSPNAME}/make/build_options.cmake)

  if (NOT DEFINED OSAL_SYSTEM_BSPTYPE)
      # Implicitly use the OSAL BSP that corresponds with the CFE PSP
      set(OSAL_SYSTEM_BSPTYPE ${CFE_PSP_EXPECTED_OSAL_BSPTYPE})
  elseif (NOT OSAL_SYSTEM_BSPTYPE STREQUAL CFE_PSP_EXPECTED_OSAL_BSPTYPE)
      # Generate a warning about the BSPTYPE not being expected.
      # Not calling this a fatal error because it could possibly be intended during development
      message(WARNING "Mismatched PSP/BSP: ${CFE_SYSTEM_PSPNAME} implies ${CFE_PSP_EXPECTED_OSAL_BSPTYPE}, but ${OSAL_SYSTEM_BSPTYPE} is configured")
  endif()

  # The "inc" directory in the binary dir contains the generated wrappers, if any
  include_directories(${MISSION_BINARY_DIR}/inc)
  include_directories(${CMAKE_BINARY_DIR}/inc)

  # Add a custom target for "headercheck" - this is a special target confirms that
  # checks the sanity of headers within the public interface of modules
  add_custom_target(check-headers)

  # Configure OSAL target first, as it also determines important compiler flags
  add_subdirectory("${osal_MISSION_DIR}" osal)

  # The OSAL displays its selected OS, so it is logical to display the selected PSP
  # This can help with debugging if things go wrong.
  message(STATUS "PSP Selection: ${CFE_SYSTEM_PSPNAME}")

  # Create a documentation content file, with any system-specific doxygen info
  # this is done here in arch_build where the CFE_SYSTEM_PSPNAME is known
  file(WRITE "${MISSION_BINARY_DIR}/docs/tgtsystem-content-${SYSVAR}.doxyfile"
    "INPUT += ${CMAKE_BINARY_DIR}/inc\n"
  )

  # The PSP and/or OSAL should have defined where to install the binaries.
  # If not, just install them in /cf as a default (this can be modified
  # by the packaging script if it is wrong for the target)
  if (NOT INSTALL_SUBDIR)
    set(INSTALL_SUBDIR cf)
  endif (NOT INSTALL_SUBDIR)

  # confirm that all dependencies have a MISSION_DIR defined that indicates the source.
  # This should have been set up by the parent script.  However, if any dir is not set,
  # this may result in "add_subdirectory" of itself which causes a loop.  This can happen
  # if the variables/lists were modified unexpectedly.
  foreach(DEP
        ${MISSION_CORE_INTERFACES}
        ${MISSION_CORE_MODULES}
        ${TGTSYS_${SYSVAR}_PSPMODULES}
        ${TGTSYS_${SYSVAR}_STATICAPPS}
        ${TGTSYS_${SYSVAR}_APPS})
    if(NOT DEFINED ${DEP}_MISSION_DIR)
      message(FATAL_ERROR "ERROR: core module ${DEP} has no MISSION_DIR defined")
    endif()
  endforeach()


  # Add all core modules
  # The osal is handled explicitly (above) since this has special extra config
  foreach(DEP ${MISSION_CORE_INTERFACES} ${MISSION_CORE_MODULES})
    if(NOT DEP STREQUAL "osal")
      message(STATUS "Building Core Module: ${DEP}")
      add_subdirectory("${${DEP}_MISSION_DIR}" ${DEP})
    endif(NOT DEP STREQUAL "osal")
  endforeach(DEP ${MISSION_CORE_MODULES})

  # For the PSP it may define the FSW as either
  # "psp-${CFE_SYSTEM_PSPNAME}" or just simply "psp"
  if (NOT TARGET psp)
    add_library(psp ALIAS psp-${CFE_SYSTEM_PSPNAME})
  endif (NOT TARGET psp)

  # Process each PSP module that is referenced on this system architecture (any cpu)
  foreach(PSPMOD ${TGTSYS_${SYSVAR}_PSPMODULES})
    message(STATUS "Building PSP Module: ${PSPMOD}")
    add_subdirectory("${${PSPMOD}_MISSION_DIR}" psp/${PSPMOD})
  endforeach()

  # Process each app that is used on this system architecture
  # First Pass: Assemble the list of apps that should be compiled
  foreach(APP ${TGTSYS_${SYSVAR}_APPS} ${TGTSYS_${SYSVAR}_STATICAPPS})
    message(STATUS "App: ${APP}")
    set(TGTLIST_${APP})
  endforeach()

  foreach(TGTNAME ${TGTSYS_${SYSVAR}})

    # Append to the app install list for this CPU
    foreach(APP ${${TGTNAME}_APPLIST} ${${TGTNAME}_STATIC_APPLIST})
      list(APPEND TGTLIST_${APP} ${TGTNAME})
    endforeach(APP ${${TGTNAME}_APPLIST})

  endforeach(TGTNAME ${TGTSYS_${SYSVAR}})
    
  foreach(APP ${TGTSYS_${SYSVAR}_STATICAPPS})
    set(APP_STATIC_TARGET_LIST ${TGTLIST_${APP}})
    message(STATUS "Building Static App: ${APP} targets=${APP_STATIC_TARGET_LIST}")
    add_subdirectory("${${APP}_MISSION_DIR}" apps/${APP})
  endforeach()
  unset(APP_STATIC_TARGET_LIST)

  # Process each app that is used on this system architecture
  message(STATUS ${TGTSYS_${SYSVAR}_APPS})
  foreach(APP ${TGTSYS_${SYSVAR}_APPS})
    set(APP_DYNAMIC_TARGET_LIST ${TGTLIST_${APP}})
    message(STATUS "Building Dynamic App: ${APP} targets=${APP_DYNAMIC_TARGET_LIST}")
    add_subdirectory("${${APP}_MISSION_DIR}" apps/${APP})
  endforeach()
  unset(APP_DYNAMIC_TARGET_LIST)
  
  # Process each target that shares this system architecture
  # Second Pass: Build and link final target executable
  foreach(TGTNAME ${TGTSYS_${SYSVAR}})

    # Target to generate the actual executable file
    add_subdirectory(cmake/target ${TGTNAME})

    include(${MISSION_DEFS}/${TGTNAME}/install_custom.cmake OPTIONAL)

    foreach(INSTFILE ${${TGTNAME}_FILELIST})
      if(EXISTS ${MISSION_DEFS}/${TGTNAME}/${INSTFILE})
        set(FILESRC ${MISSION_DEFS}/${TGTNAME}/${INSTFILE})
      elseif(EXISTS ${MISSION_DEFS}/${TGTNAME}_${INSTFILE})
        set(FILESRC ${MISSION_DEFS}/${TGTNAME}_${INSTFILE})
      elseif(EXISTS ${MISSION_DEFS}/${INSTFILE})
        set(FILESRC ${MISSION_DEFS}/${INSTFILE})
      else()
        set(FILESRC)
      endif()
      if (FILESRC)
        # In case the file is a symlink, follow it to get to the actual file
        get_filename_component(FILESRC "${FILESRC}" REALPATH)
        message("NOTE: Selected ${FILESRC} as source for ${INSTFILE} on ${TGTNAME}")
        install(FILES ${FILESRC} DESTINATION ${TGTNAME}/${INSTALL_SUBDIR} RENAME ${INSTFILE})
      else(FILESRC)
        message("WARNING: Install file ${INSTFILE} for ${TGTNAME} not found")
      endif (FILESRC)
    endforeach(INSTFILE ${${TGTNAME}_FILELIST})
  endforeach(TGTNAME ${TGTSYS_${SYSVAR}})

endfunction(process_arch SYSVAR)


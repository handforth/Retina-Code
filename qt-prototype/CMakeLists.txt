cmake_minimum_required(VERSION 3.21)
project(RetinaCodePrototype LANGUAGES CXX)

find_package(Qt6 6.8 REQUIRED COMPONENTS Widgets)

qt_add_executable(RetinaCodePrototype WIN32 MACOSX_BUNDLE
    main.cpp
    RunPane.cpp
    ../source/Lexer.cpp
    ../source/Languages.cpp
    ../source/RunText.cpp
    ../source/Typing.cpp
)
target_compile_features(RetinaCodePrototype PRIVATE cxx_std_20)
target_include_directories(RetinaCodePrototype PRIVATE ../source)
target_link_libraries(RetinaCodePrototype PRIVATE Qt6::Widgets)

qt_add_resources(RetinaCodePrototype app_icon
    PREFIX "/"
    FILES icons/retina-code.ico
)

if(WIN32)
    enable_language(RC)
    set_source_files_properties(icons/retina-code.rc PROPERTIES
        INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/icons"
        OBJECT_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/icons/retina-code.ico"
    )
    target_sources(RetinaCodePrototype PRIVATE icons/retina-code.rc)
    target_link_libraries(RetinaCodePrototype PRIVATE psapi)
elseif(APPLE)
    set_source_files_properties(icons/retina-code.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_sources(RetinaCodePrototype PRIVATE icons/retina-code.icns)
    set_target_properties(RetinaCodePrototype PROPERTIES MACOSX_BUNDLE_ICON_FILE retina-code.icns)
endif()

if(MSVC)
    target_compile_options(RetinaCodePrototype PRIVATE /utf-8)
endif()

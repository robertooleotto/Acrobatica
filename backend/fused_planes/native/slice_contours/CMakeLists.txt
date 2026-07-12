cmake_minimum_required(VERSION 3.16)
project(slice_contours LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(CGAL REQUIRED)

add_executable(slice_contours main.cpp)
target_link_libraries(slice_contours PRIVATE CGAL::CGAL)

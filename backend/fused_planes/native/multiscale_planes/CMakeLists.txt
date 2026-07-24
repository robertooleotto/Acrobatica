cmake_minimum_required(VERSION 3.16)
project(cgal_multiscale_planes LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(CGAL REQUIRED)
find_package(Eigen3 REQUIRED NO_MODULE)

add_executable(cgal_multiscale_planes main.cpp)
target_link_libraries(cgal_multiscale_planes PRIVATE CGAL::CGAL Eigen3::Eigen)

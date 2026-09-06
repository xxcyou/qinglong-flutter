cmake_minimum_required(VERSION 3.10)
project(qtermpty C)

add_library(qtermpty SHARED qtermpty.c)
target_link_libraries(qtermpty log)

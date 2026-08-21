#ifndef KADATH_RUNTIME_CORE_TEST_HOOKS_H
#define KADATH_RUNTIME_CORE_TEST_HOOKS_H

#include <stdint.h>

#include "kadath_runtime_core.h"

#define KADATH_RUNTIME_TEST_ENTRY_PREPARE 1U
#define KADATH_RUNTIME_TEST_ENTRY_QUERY 2U
#define KADATH_RUNTIME_TEST_ENTRY_MUTATE 3U

#define KADATH_RUNTIME_TEST_FAULT_PANIC_BEFORE_PUBLICATION 1U
#define KADATH_RUNTIME_TEST_FAULT_ALLOCATION_FAILURE 2U

typedef struct kadath_runtime_test_fault_desc_t {
    uint32_t struct_size;
    uint32_t entry;
    uint32_t fault;
    uint32_t reserved0;
    uint64_t reserved[4];
} kadath_runtime_test_fault_desc_t;

int32_t kadath_runtime_core_test_arm_next_fault(
    kadath_runtime_core_t* core,
    const kadath_runtime_test_fault_desc_t* desc);

#endif

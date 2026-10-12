#!/usr/bin/env python3
"""Run position-only recovery and unrelated-retirement regression scenarios.

Uses the shared adapter to execute unchanged production Swift method bodies.
This is deterministic application-state coverage, not AVKit/device validation.
"""
import sys
sys.dont_write_bytecode = True
from run_presentation_review import main

if __name__ == '__main__':
    main(default_case_group='position-recovery')

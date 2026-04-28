;
//  Timer.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

.global enable_core_timer
enable_core_timer:
    // Read Timer HW Frequency
    mrs     x0, cntfrq_el0
    
    // Preemptive 10ms
    mov     x1, #100
    udiv    x0, x0, x1
    
    // Set value on Countdown register (Timer Value)
    msr     cntp_tval_el0, x0
    
    // Start timer (bit 0 to 1 is "ENABLE")
    mov     x0, #1
    msr     cntp_ctl_el0, x0
    
    ret

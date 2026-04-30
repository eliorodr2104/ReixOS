//  Timer.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

.global enable_core_timer
enable_core_timer:
    mrs     x0, cntfrq_el0
    mov     x1, #100
    udiv    x0, x0, x1
    
    msr     cntv_tval_el0, x0    // Timer Value (Virtual)
    
    mov     x0, #1
    msr     cntv_ctl_el0, x0     // Control Register (Virtual)
    ret

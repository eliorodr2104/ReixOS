//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: PhysicalPageManager?
    private static var vmm: VirtualMemoryManager?
    public  static var internalPanicMessage: String?

    
    public static func boot(dtbAddress: PhysicalAddress) {
        
        do {
            self.ppm = try PhysicalPageManager(
                dtbRawAddress: dtbAddress
            )
            kprint("\nInit PPM!")
            
            
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            kprint("Init VMM!")
            
            KernelHeap.initialize(ppmPtr: &ppm!)
//            
            try testKernelHeap()
            
        } catch { internalPanic(error) }
        
        
        do {
            try run()
            
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprint("\nKernel is running")
        CPUArm64.waitForInterrupt()
        
//        do {
//            try ppm?.testPPM()
//            
//        } catch { throw KernelError(error) }
    }
    
    private static func internalPanic(_ error: KernelError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
    
    private static func internalPanic(_ error: AllocatorError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
    
    private static func internalPanic(_ error: PPMError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
    
    public static func testKernelHeap() throws(PPMError) {
        // Se hai una funzione di print per la tua UART, usala qui.
        // Altrimenti fidati dei Panic per capire se fallisce.
        
        // --- TEST 1: Allocazione e Scrittura ---
        // Chiediamo 42 byte. Il sistema deve arrotondare a 64 e darci un puntatore.
        guard let ptr1 = try KernelHeap.kmalloc(42) else {
            CPUArm64.panic() // Fallita la prima allocazione!
            return
        }
        
        // Proviamo a scriverci dentro. Se il VMM non ha mappato bene la pagina,
        // la CPU andrà in Data Abort / Translation Fault qui.
        let typedPtr1 = ptr1.assumingMemoryBound(to: UInt64.self)
        typedPtr1.pointee = 0xDEADBEEF_CAFEBABE // Scriviamo un pattern riconoscibile
        
        // --- TEST 2: Allocazione di un secondo blocco ---
        // Chiediamo altri 64 byte. Dovrebbe darci il blocco immediatamente successivo
        // nella pagina che ha appena affettato.
        guard let ptr2 = try KernelHeap.kmalloc(64) else {
            CPUArm64.panic()
            return
        }
        
        // Assicuriamoci che i due puntatori siano diversi!
        if ptr1 == ptr2 {
            CPUArm64.panic() // Errore critico: ci ha dato lo stesso blocco due volte!
        }
        
        // --- TEST 3: Deallocazione (Il ritorno nel cassetto) ---
        KernelHeap.kfree(ptr1)
        
        // --- TEST 4: La prova del nove (LIFO) ---
        // Ora chiediamo di nuovo 64 byte. Visto che abbiamo appena liberato ptr1,
        // il bucket[3] dovrebbe avere ptr1 in testa. kmalloc DEVE restituirci ptr1.
        guard let ptr3 = try KernelHeap.kmalloc(64) else {
            CPUArm64.panic()
        }
        
        if ptr3 != ptr1 {
            // Se arrivi qui, la kfree non ha aggiornato correttamente la testa del cassetto,
            // oppure la kmalloc non sta leggendo bene la lista intrinseca.
            CPUArm64.panic()
        }
        
        // Se il tuo kernel arriva a questa riga senza esplodere... COMPLIMENTI!
        // Hai un Kernel Heap funzionante.
        
        // Pulizia finale per non lasciare sporco
        KernelHeap.kfree(ptr2)
        KernelHeap.kfree(ptr3)
    }
}

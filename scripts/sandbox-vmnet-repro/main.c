/*
 * SandboxVmnetRepro — minimal reproduction of an App Sandbox regression on
 * macOS 27 betas (26A5378n through 26A5425a):
 *
 *   A sandboxed process holding com.apple.security.virtualization can no
 *   longer create a VMNET_SHARED_MODE network. vmnet's NAT setup
 *   (_NETRBCreateNetwork) performs a mach bootstrap look-up of
 *   com.apple.NetworkSharing, which the App Sandbox now denies:
 *
 *     [com.apple.xpc:connection] failed to do a bootstrap look-up:
 *         xpc_error=[159: Unknown error: 159]
 *     [com.apple.xpc:connection] invalidated after a failed init
 *
 *   Depending on the seed, vmnet_network_create() then either returns NULL
 *   with VMNET_MEM_FAILURE (1002) or never returns at all (observed on
 *   26A5406e and 26A5425a). The same binary without the sandbox — or
 *   sandboxed with a temporary-exception mach-lookup entitlement for
 *   com.apple.NetworkSharing — succeeds.
 *
 * Build and run all three signing variants with ./build-and-run.sh.
 */

#include <vmnet/vmnet.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void)
{
    fprintf(stderr, "[repro] pid %d starting\n", getpid());

    vmnet_return_t status = 0;
    vmnet_network_configuration_ref config =
        vmnet_network_configuration_create(VMNET_SHARED_MODE, &status);
    if (config == NULL) {
        printf("RESULT: FAIL vmnet_network_configuration_create returned NULL (status=%d)\n",
               (int)status);
        return 1;
    }
    fprintf(stderr, "[repro] configuration created (status=%d), calling vmnet_network_create...\n",
            (int)status);

    /* On affected seeds vmnet_network_create() sometimes hangs forever instead
     * of failing fast; a watchdog turns that into a deterministic result. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        printf("RESULT: HANG vmnet_network_create did not return within 30s\n");
        fflush(stdout);
        _exit(2);
    });

    status = 0;
    vmnet_network_ref network = vmnet_network_create(config, &status);
    if (network == NULL) {
        printf("RESULT: FAIL vmnet_network_create returned NULL (status=%d; VMNET_MEM_FAILURE=1002)\n",
               (int)status);
        return 1;
    }

    printf("RESULT: PASS vmnet_network_create succeeded (status=%d)\n", (int)status);
    CFRelease(network);
    CFRelease(config);
    return 0;
}

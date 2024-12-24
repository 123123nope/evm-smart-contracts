import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { verify } from '../helpers';

export class CustomRuntimeEnvironment {
    constructor(private readonly hre: HardhatRuntimeEnvironment) {}

    async getTimelock(address: string) {
        const timelock = await this.hre.ethers.getContractAt(
            'ITimelockController',
            address
        );

        console.log(`Timelock found at ${await timelock.getAddress()}`);

        return timelock;
    }

    async getProxyAdmin(proxy: string) {
        const proxyAdmin = await this.hre.ethers.getContractAt(
            'IProxyAdmin',
            await this.hre.upgrades.erc1967.getAdminAddress(proxy)
        );

        console.log(
            `ProxyAdmin of ${proxy} found at ${await proxyAdmin.getAddress()}`
        );

        return proxyAdmin;
    }

    async deployImplementation(contract: string): Promise<string> {
        // TODO: verify storage

        console.log(`Deploying ${contract} implementation`);

        const impl = await this.hre.ethers.deployContract(contract);
        await impl.waitForDeployment();

        const addr = await impl.getAddress();

        console.log(
            `New implementation of ${contract} deployed at ${addr}, verifying...`
        );

        await verify(run, addr);

        return addr;
    }
}

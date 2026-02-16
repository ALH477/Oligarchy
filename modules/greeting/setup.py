from setuptools import setup, find_packages

setup(
    name="nixos-welcome-tui",
    version="1.0.0",
    description="NixOS Welcome TUI - Interactive terminal greeting",
    author="NixOS Community",
    license="MIT",
    py_modules=["welcome_tui"],
    install_requires=[
        "textual>=0.47.0",
    ],
    entry_points={
        "console_scripts": [
            "welcome-tui=welcome_tui:main",
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Environment :: Console",
        "Intended Audience :: System Administrators",
        "License :: OSI Approved :: MIT License",
        "Operating System :: POSIX :: Linux",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
    ],
    python_requires=">=3.10",
)

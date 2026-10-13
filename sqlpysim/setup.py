from setuptools import setup

with open("README.md", "r", encoding="utf-8") as f:
    long_description = f.read()

setup(
    name="sqlpysim",
    version="1.0.0",
    author="Bob Ward",
    description="Python SQL Workload Simulator using mssql-python driver",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/microsoft/sqlsimtools",
    py_modules=["sqlpysim"],
    python_requires=">=3.10",
    install_requires=[
        "mssql-python==1.15.0",
    ],
    entry_points={
        "console_scripts": [
            "sqlpysim=sqlpysim:main",
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "Intended Audience :: System Administrators",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Topic :: Database",
        "Topic :: Software Development :: Testing",
    ],
)
